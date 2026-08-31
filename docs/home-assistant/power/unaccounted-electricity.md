# Manual unaccounted electricity report

Run the read-only report:

```console
mise run home-assistant:unaccounted-electricity
```

Get structured output, including the five-minute graph series:

```console
mise run home-assistant:unaccounted-electricity --format json
```

The command runs the analysis inside the Home Assistant pod. It uses the pod's
existing recorder connection and does not print or store database credentials.

## Method

The report uses the latest complete short-term statistics timestamp as the end
of a 24-hour window.

1. Whole-home energy is the change in the Octopus electricity meter's
   accumulative-consumption statistic.
2. Accounted energy is the combined change from the device-consumption sensors
   configured in the Home Assistant Energy dashboard when this script was
   created.
3. Unaccounted energy is whole-home energy minus accounted energy.
4. Residual demand is whole-home current demand minus one non-overlapping power
   sensor for each accounted load.
5. Residual samples are reduced to five-minute medians. This limits false peaks
   caused by sensors updating at slightly different times.
6. Estimated base load is the 10th percentile of the five-minute residual.
7. The normal upper bound is the 90th percentile.
8. The spike threshold is the 95th percentile. A spike is reported only when
   two or more consecutive five-minute bins meet that threshold.

The command fails instead of returning a partial result when required entities are
missing, energy statistics do not span the complete window, or residual-demand
coverage is below 95%.

## Limits

The Energy dashboard device list is a checked-in snapshot. Update
`ACCOUNTED_ENERGY_ENTITIES` and `ACCOUNTED_POWER_ENTITIES` in
`scripts/home_assistant_unaccounted_electricity.py` when the dashboard changes.

Unaccounted demand includes genuinely unmetered loads, modelled standby errors,
meter precision, accounted energy sensors without live power history, and
remaining timing differences. A reported spike is a reason to correlate entity
state changes; it does not identify a device by itself.
