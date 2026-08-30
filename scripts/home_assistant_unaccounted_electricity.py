from __future__ import annotations

import argparse
import bisect
import json
import math
import os
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any, Sequence


GRID_ENERGY_ENTITY = (
    "sensor.octopus_energy_electricity_19m1031608_"
    "1460000730277_current_accumulative_consumption"
)
GRID_DEMAND_ENTITY = (
    "sensor.octopus_energy_electricity_19m1031608_"
    "1460000730277_current_demand"
)

# Snapshot of Home Assistant's Energy dashboard device-consumption list.
ACCOUNTED_ENERGY_ENTITIES = [
    "sensor.unnamed_p110m_today_s_consumption_3",
    "sensor.spare_energy",
    "sensor.unnamed_p110m_today_s_consumption",
    "sensor.heated_air_dryer_p110m_today_s_consumption",
    "sensor.garage_network_today_s_consumption",
    "sensor.tv_socket_today_s_consumption",
    "sensor.washing_machine_today_s_consumption",
    "sensor.rack_energy_daily",
    "sensor.office_switch_today_s_consumption",
    "sensor.office_2_today_s_consumption",
    "sensor.office_3_today_s_consumption",
    "sensor.unnamed_p110m_today_s_consumption_2",
    "sensor.string_lights_today_s_consumption",
    "sensor.outdoor_lights_energy",
    "sensor.loft_lights_energy",
    "sensor.downstairs_light_fixtures_energy",
    "sensor.upstairs_light_fixtures_energy",
    "sensor.sonos_speakers_energy",
]

# One non-overlapping live power sensor for each metered load where available.
ACCOUNTED_POWER_ENTITIES = [
    "sensor.unnamed_p110m_current_consumption_3",
    "sensor.spare_power",
    "sensor.unnamed_p110m_current_consumption",
    "sensor.heated_air_dryer_p110m_current_consumption",
    "sensor.garage_network_current_consumption",
    "sensor.tv_socket_current_consumption",
    "sensor.washing_machine_current_consumption",
    "sensor.rack_switch_power",
    "sensor.office_switch_current_consumption",
    "sensor.unnamed_p110m_current_consumption_2",
    "sensor.outdoor_lights_power",
    "sensor.downstairs_light_fixtures_power",
    "sensor.upstairs_light_fixtures_power",
    "sensor.sonos_speakers_power",
]

STATISTICS_META_SQL = """
SELECT statistic_id, id
FROM statistics_meta
WHERE statistic_id = ANY(%s)
"""

LATEST_STATISTIC_SQL = """
SELECT max(start_ts)
FROM statistics_short_term
WHERE metadata_id = %s
"""

STATISTIC_RANGE_SQL = """
SELECT start_ts, sum
FROM statistics_short_term
WHERE metadata_id = %s
  AND start_ts BETWEEN %s AND %s
ORDER BY start_ts
"""

STATE_META_SQL = """
SELECT entity_id, metadata_id
FROM states_meta
WHERE entity_id = ANY(%s)
"""

NUMERIC_STATE_HISTORY_SQL = """
(SELECT last_updated_ts, state
 FROM states
 WHERE metadata_id = %s
   AND last_updated_ts <= %s
   AND state ~ '^-?[0-9]+([.][0-9]+)?$'
 ORDER BY last_updated_ts DESC
 LIMIT 1)
UNION ALL
(SELECT last_updated_ts, state
 FROM states
 WHERE metadata_id = %s
   AND last_updated_ts > %s
   AND last_updated_ts <= %s
   AND state ~ '^-?[0-9]+([.][0-9]+)?$'
 ORDER BY last_updated_ts)
ORDER BY last_updated_ts
"""

NUMERIC_DEMAND_SQL = """
SELECT last_updated_ts, state::double precision
FROM states
WHERE metadata_id = %s
  AND last_updated_ts >= %s
  AND last_updated_ts <= %s
  AND state ~ '^-?[0-9]+([.][0-9]+)?$'
ORDER BY last_updated_ts
"""


def percentile(values: Sequence[float], proportion: float) -> float:
    if not values:
        raise ValueError("cannot calculate a percentile without values")
    if not 0 <= proportion <= 1:
        raise ValueError("percentile proportion must be between 0 and 1")
    ordered = sorted(values)
    position = (len(ordered) - 1) * proportion
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    return (
        ordered[lower] * (upper - position)
        + ordered[upper] * (position - lower)
    )


def energy_totals(
    *,
    grid_start: float,
    grid_end: float,
    device_ranges: dict[str, tuple[float, float]],
) -> dict[str, float]:
    whole_home = grid_end - grid_start
    device_deltas = {
        entity_id: end - start
        for entity_id, (start, end) in device_ranges.items()
    }
    negative = [entity_id for entity_id, delta in device_deltas.items() if delta < 0]
    if whole_home <= 0:
        raise ValueError("whole-home energy did not increase")
    if negative:
        raise ValueError(
            "accounted energy decreased for: " + ", ".join(sorted(negative))
        )
    accounted = sum(device_deltas.values())
    unaccounted = whole_home - accounted
    return {
        "whole_home_kwh": round(whole_home, 6),
        "accounted_kwh": round(accounted, 6),
        "unaccounted_kwh": round(unaccounted, 6),
        "unaccounted_percent": round(unaccounted / whole_home * 100, 2),
    }


def residual_points(
    demand_samples: Sequence[tuple[float, float]],
    power_histories: dict[str, Sequence[tuple[float, float]]],
    *,
    bucket_seconds: int = 300,
) -> list[dict[str, float]]:
    prepared = {
        entity_id: (
            [timestamp for timestamp, _ in samples],
            [value for _, value in samples],
        )
        for entity_id, samples in power_histories.items()
    }
    buckets: dict[int, list[float]] = defaultdict(list)
    for timestamp, whole_home_w in demand_samples:
        accounted_w = 0.0
        for timestamps, values in prepared.values():
            index = bisect.bisect_right(timestamps, timestamp) - 1
            if index >= 0:
                accounted_w += values[index]
        bucket = int(timestamp // bucket_seconds) * bucket_seconds
        buckets[bucket].append(whole_home_w - accounted_w)
    return [
        {
            "timestamp": float(timestamp),
            "residual_w": round(statistics.median(values), 1),
        }
        for timestamp, values in sorted(buckets.items())
    ]


def sustained_spikes(
    points: Sequence[dict[str, float]],
    *,
    threshold_w: float,
    minimum_bins: int = 2,
) -> list[dict[str, float | int]]:
    runs: list[list[dict[str, float]]] = []
    current: list[dict[str, float]] = []
    for point in points:
        if point["residual_w"] >= threshold_w:
            current.append(point)
            continue
        if current:
            runs.append(current)
            current = []
    if current:
        runs.append(current)
    return [
        {
            "start_timestamp": run[0]["timestamp"],
            "end_timestamp": run[-1]["timestamp"],
            "peak_w": max(point["residual_w"] for point in run),
            "bins": len(run),
        }
        for run in runs
        if len(run) >= minimum_bins
    ]


def analysis_summary(
    totals: dict[str, float],
    points: Sequence[dict[str, float]],
    *,
    window_start: float,
    window_end: float,
) -> dict[str, Any]:
    values = [point["residual_w"] for point in points]
    if not values:
        raise ValueError("no residual-demand points were available")
    duration_hours = (window_end - window_start) / 3600
    p95 = percentile(values, 0.95)
    return {
        **totals,
        "window_start": iso_timestamp(window_start),
        "window_end": iso_timestamp(window_end),
        "average_unaccounted_w": round(
            totals["unaccounted_kwh"] * 1000 / duration_hours,
            1,
        ),
        "base_w": round(percentile(values, 0.10), 1),
        "median_w": round(percentile(values, 0.50), 1),
        "p90_w": round(percentile(values, 0.90), 1),
        "p95_w": round(p95, 1),
        "max_5m_w": round(max(values), 1),
        "sustained_spikes": sustained_spikes(points, threshold_w=p95),
        "points": [
            {
                "timestamp": iso_timestamp(point["timestamp"]),
                "residual_w": point["residual_w"],
            }
            for point in points
        ],
    }


def iso_timestamp(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def database_url() -> str:
    try:
        value = os.environ["HASS_POSTGRES_URL"]
    except KeyError as error:
        raise RuntimeError("HASS_POSTGRES_URL is not set") from error
    return value.replace("postgresql+psycopg2://", "postgresql://", 1)


def fetch_series(
    cursor: Any,
    metadata_id: int,
    start_timestamp: float,
    end_timestamp: float,
) -> list[tuple[float, float]]:
    cursor.execute(
        STATISTIC_RANGE_SQL,
        (metadata_id, start_timestamp, end_timestamp),
    )
    return [(float(timestamp), float(value)) for timestamp, value in cursor.fetchall()]


def analyse(cursor: Any, *, hours: int, minimum_coverage: float) -> dict[str, Any]:
    energy_entities = [GRID_ENERGY_ENTITY, *ACCOUNTED_ENERGY_ENTITIES]
    cursor.execute(STATISTICS_META_SQL, (energy_entities,))
    statistic_ids = {
        statistic_id: metadata_id
        for statistic_id, metadata_id in cursor.fetchall()
    }
    missing_energy = sorted(set(energy_entities) - set(statistic_ids))
    if missing_energy:
        raise RuntimeError(
            "missing energy statistics: " + ", ".join(missing_energy)
        )

    cursor.execute(LATEST_STATISTIC_SQL, (statistic_ids[GRID_ENERGY_ENTITY],))
    latest_row = cursor.fetchone()
    if latest_row is None or latest_row[0] is None:
        raise RuntimeError("whole-home energy has no short-term statistics")
    window_end = float(latest_row[0])
    window_start = window_end - hours * 3600

    energy_series = {
        entity_id: fetch_series(
            cursor,
            metadata_id,
            window_start,
            window_end,
        )
        for entity_id, metadata_id in statistic_ids.items()
    }
    incomplete = [
        entity_id
        for entity_id, samples in energy_series.items()
        if len(samples) < 2
        or samples[0][0] != window_start
        or samples[-1][0] != window_end
    ]
    if incomplete:
        raise RuntimeError(
            "incomplete energy statistics: " + ", ".join(sorted(incomplete))
        )

    grid_series = energy_series[GRID_ENERGY_ENTITY]
    totals = energy_totals(
        grid_start=grid_series[0][1],
        grid_end=grid_series[-1][1],
        device_ranges={
            entity_id: (energy_series[entity_id][0][1], energy_series[entity_id][-1][1])
            for entity_id in ACCOUNTED_ENERGY_ENTITIES
        },
    )

    state_entities = [GRID_DEMAND_ENTITY, *ACCOUNTED_POWER_ENTITIES]
    cursor.execute(STATE_META_SQL, (state_entities,))
    state_ids = {
        entity_id: metadata_id
        for entity_id, metadata_id in cursor.fetchall()
    }
    missing_states = sorted(set(state_entities) - set(state_ids))
    if missing_states:
        raise RuntimeError("missing power states: " + ", ".join(missing_states))

    power_histories: dict[str, list[tuple[float, float]]] = {}
    for entity_id in ACCOUNTED_POWER_ENTITIES:
        metadata_id = state_ids[entity_id]
        cursor.execute(
            NUMERIC_STATE_HISTORY_SQL,
            (
                metadata_id,
                window_start,
                metadata_id,
                window_start,
                window_end,
            ),
        )
        power_histories[entity_id] = [
            (float(timestamp), float(value))
            for timestamp, value in cursor.fetchall()
        ]
        if not power_histories[entity_id]:
            raise RuntimeError(f"no numeric power state for {entity_id}")

    cursor.execute(
        NUMERIC_DEMAND_SQL,
        (
            state_ids[GRID_DEMAND_ENTITY],
            window_start,
            window_end,
        ),
    )
    demand_samples = [
        (float(timestamp), float(value))
        for timestamp, value in cursor.fetchall()
    ]
    points = residual_points(demand_samples, power_histories)
    expected_points = hours * 12
    coverage = len(points) / expected_points
    if coverage < minimum_coverage:
        raise RuntimeError(
            f"residual-demand coverage {coverage:.1%} is below "
            f"the required {minimum_coverage:.1%}"
        )
    summary = analysis_summary(
        totals,
        points,
        window_start=window_start,
        window_end=window_end,
    )
    summary["coverage_percent"] = round(coverage * 100, 1)
    summary["configuration"] = {
        "grid_energy_entity": GRID_ENERGY_ENTITY,
        "grid_demand_entity": GRID_DEMAND_ENTITY,
        "accounted_energy_entities": ACCOUNTED_ENERGY_ENTITIES,
        "accounted_power_entities": ACCOUNTED_POWER_ENTITIES,
    }
    return summary


def human_output(result: dict[str, Any]) -> str:
    lines = [
        "Unaccounted electricity",
        f"Window:              {result['window_start']} to {result['window_end']}",
        f"Whole-home:          {result['whole_home_kwh']:.3f} kWh",
        f"Accounted:           {result['accounted_kwh']:.3f} kWh",
        (
            f"Unaccounted:         {result['unaccounted_kwh']:.3f} kWh "
            f"({result['unaccounted_percent']:.1f}%)"
        ),
        f"Average residual:    {result['average_unaccounted_w']:.1f} W",
        f"Estimated base:      {result['base_w']:.1f} W",
        (
            f"Normal range:        {result['base_w']:.1f}–"
            f"{result['p90_w']:.1f} W"
        ),
        f"95th percentile:     {result['p95_w']:.1f} W",
        f"Maximum 5-minute:    {result['max_5m_w']:.1f} W",
        f"Sustained spikes:    {len(result['sustained_spikes'])}",
        f"Demand coverage:     {result['coverage_percent']:.1f}%",
        "",
        "Use --format json for the five-minute graph series.",
    ]
    return "\n".join(lines)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Calculate Home Assistant whole-home, accounted, and residual "
            "electricity for a completed lookback window."
        )
    )
    parser.add_argument(
        "--format",
        choices=("human", "json"),
        default="human",
        help="output format (default: human)",
    )
    parser.add_argument(
        "--hours",
        type=int,
        default=24,
        help="completed lookback window in hours (default: 24)",
    )
    parser.add_argument(
        "--minimum-coverage",
        type=float,
        default=0.95,
        help="minimum residual-demand coverage from 0 to 1 (default: 0.95)",
    )
    args = parser.parse_args(argv)
    if args.hours <= 0:
        parser.error("--hours must be greater than zero")
    if not 0 < args.minimum_coverage <= 1:
        parser.error("--minimum-coverage must be greater than zero and at most one")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        import psycopg2

        with psycopg2.connect(database_url()) as connection:
            with connection.cursor() as cursor:
                result = analyse(
                    cursor,
                    hours=args.hours,
                    minimum_coverage=args.minimum_coverage,
                )
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.format == "json":
        print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    else:
        print(human_output(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
