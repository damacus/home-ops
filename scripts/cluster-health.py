#!/usr/bin/env python3
"""Read-only cluster health checks for recurring operator diagnostics."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.parse
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from typing import Any, Final


ALERT_QUERY: Final[str] = 'ALERTS{alertstate="firing",alertname!="Watchdog"}'
PROMETHEUS_QUERY_URL: Final[str] = (
    "http://vmsingle-vm.monitoring.svc.cluster.local:8428/api/v1/query?query={query}"
)
ALERTMANAGER_URL: Final[str] = "http://localhost:9093/api/v2/alerts"
EXEC_POD: Final[list[str]] = ["kubectl", "exec", "-n", "monitoring", "vmalertmanager-vm-0", "--"]
STALE_BACKUP_SECONDS: Final[int] = 30 * 60
HIBERNATION_ANNOTATION: Final[str] = "cnpg.io/hibernation"


@dataclass
class CheckResult:
    name: str
    status: str
    summary: str
    details: list[str]

    @property
    def failed(self) -> bool:
        return self.status == "fail"


def run(command: list[str], input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, input=input_text, check=False, capture_output=True, text=True)


def kubectl_json(args: list[str]) -> Any:
    result = run(["kubectl", *args, "-o", "json"])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"kubectl {' '.join(args)} failed")
    return json.loads(result.stdout)


def remote_get(url: str) -> Any:
    result = run([*EXEC_POD, "wget", "-qO-", url])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"request failed: {url}")
    return json.loads(result.stdout)


def parse_ready(value: str) -> tuple[int, int]:
    ready, total = value.split("/", 1)
    return int(ready), int(total)


def check_nodes() -> CheckResult:
    nodes = kubectl_json(["get", "nodes"])
    bad = []
    for node in nodes["items"]:
        ready = next(
            (condition for condition in node["status"]["conditions"] if condition["type"] == "Ready"),
            None,
        )
        if ready is None or ready.get("status") != "True":
            bad.append(node["metadata"]["name"])
    status = "pass" if not bad else "fail"
    return CheckResult(
        "nodes",
        status,
        "all nodes Ready" if not bad else f"{len(bad)} nodes not Ready",
        bad,
    )


def check_kube_vip() -> CheckResult:
    pods = kubectl_json(["get", "pods", "-n", "kube-system", "-l", "app.kubernetes.io/name=kube-vip"])
    bad = []
    for pod in pods["items"]:
        containers = pod["status"].get("containerStatuses", [])
        if pod["status"].get("phase") != "Running" or any(not container.get("ready") for container in containers):
            bad.append(pod["metadata"]["name"])
    status = "pass" if not bad and pods["items"] else "fail"
    summary = f"{len(pods['items'])} kube-vip pods ready" if status == "pass" else "kube-vip pod readiness failed"
    return CheckResult("kube-vip", status, summary, bad)


def check_cilium() -> CheckResult:
    result = run(["kubectl", "exec", "-n", "kube-system", "ds/cilium", "--", "cilium-dbg", "status", "--brief"])
    output = "\n".join(part for part in [result.stdout.strip(), result.stderr.strip()] if part)
    return CheckResult(
        "cilium",
        "pass" if result.returncode == 0 and output.strip() == "OK" else "fail",
        "Cilium status OK" if result.returncode == 0 and output.strip() == "OK" else "Cilium status check failed",
        [output] if output else [],
    )


def check_not_ready_pods() -> CheckResult:
    pods = kubectl_json(["get", "pods", "-A"])
    bad = []
    ignored_phases = {"Succeeded"}
    for pod in pods["items"]:
        phase = pod["status"].get("phase", "")
        if phase in ignored_phases:
            continue
        statuses = pod["status"].get("containerStatuses", [])
        waiting_reasons = [
            status.get("state", {}).get("waiting", {}).get("reason")
            for status in statuses
            if status.get("state", {}).get("waiting", {}).get("reason")
        ]
        ready_count = sum(1 for status in statuses if status.get("ready"))
        total = len(statuses)
        if phase != "Running" or waiting_reasons or (total and ready_count != total):
            name = f"{pod['metadata']['namespace']}/{pod['metadata']['name']}"
            reason = ",".join(waiting_reasons) or phase or f"{ready_count}/{total} ready"
            bad.append(f"{name}: {reason}")
    status = "pass" if not bad else "fail"
    return CheckResult(
        "pods",
        status,
        "all active pods ready" if not bad else f"{len(bad)} active pods not ready",
        bad[:30],
    )


def check_deployments() -> CheckResult:
    deployments = kubectl_json(["get", "deploy", "-A"])
    bad = []
    for deploy in deployments["items"]:
        spec = deploy.get("spec", {})
        status = deploy.get("status", {})
        desired = spec.get("replicas", 1)
        ready = status.get("readyReplicas", 0)
        available = status.get("availableReplicas", 0)
        if ready != desired or available != desired:
            bad.append(f"{deploy['metadata']['namespace']}/{deploy['metadata']['name']}: {ready}/{desired} ready")
    return CheckResult(
        "deployments",
        "pass" if not bad else "fail",
        "all deployments available" if not bad else f"{len(bad)} deployments unavailable",
        bad,
    )


def cnpg_clusters() -> CheckResult:
    clusters = kubectl_json(["get", "clusters.postgresql.cnpg.io", "-A"])
    bad = []
    for cluster in clusters["items"]:
        status = cluster.get("status", {})
        instances = int(status.get("instances", cluster.get("spec", {}).get("instances", 0)) or 0)
        ready = int(status.get("readyInstances", 0) or 0)
        phase = status.get("phase", "")
        name = f"{cluster['metadata']['namespace']}/{cluster['metadata']['name']}"
        if phase != "Cluster in healthy state" or ready != instances:
            bad.append(f"{name}: {phase}, ready {ready}/{instances}")
    return CheckResult(
        "cnpg-clusters",
        "pass" if not bad else "fail",
        "all CNPG clusters healthy" if not bad else f"{len(bad)} CNPG clusters unhealthy",
        bad,
    )


def cnpg_backups() -> CheckResult:
    backups = kubectl_json(["get", "backups.postgresql.cnpg.io", "-A"])["items"]
    clusters = kubectl_json(["get", "clusters.postgresql.cnpg.io", "-A"])["items"]
    by_cluster: dict[str, list[dict[str, Any]]] = {}
    for backup in backups:
        key = f"{backup['metadata']['namespace']}/{backup['spec']['cluster']['name']}"
        by_cluster.setdefault(key, []).append(backup)

    bad: list[str] = []
    details: list[str] = []
    for cluster in clusters:
        namespace = cluster["metadata"]["namespace"]
        name = cluster["metadata"]["name"]
        key = f"{namespace}/{name}"
        if cnpg_cluster_hibernated(cluster):
            details.append(f"{key}: hibernated, backup/WAL check skipped")
            continue
        cluster_backups = sorted(
            by_cluster.get(key, []),
            key=lambda item: item.get("status", {}).get("startedAt") or item["metadata"]["creationTimestamp"],
        )
        latest = cluster_backups[-1] if cluster_backups else None
        latest_success = next(
            (backup for backup in reversed(cluster_backups) if backup.get("status", {}).get("phase") == "completed"),
            None,
        )
        latest_phase = latest.get("status", {}).get("phase", "unknown") if latest else "missing"
        latest_success_time = latest_success.get("status", {}).get("stoppedAt", "-") if latest_success else "-"
        details.append(f"{key}: latest={latest_phase}, last_success={latest_success_time}")

        if latest is None:
            bad.append(f"{key}: no Backup resources found")
        elif latest_phase == "failed":
            error = latest.get("status", {}).get("error", "unknown error")
            bad.append(f"{key}: latest backup failed: {error}")
        elif latest_phase == "started":
            started_at = latest.get("status", {}).get("startedAt") or latest["metadata"]["creationTimestamp"]
            if age_seconds(started_at) > STALE_BACKUP_SECONDS:
                bad.append(f"{key}: latest backup still started since {started_at}")
        if latest_success is None:
            bad.append(f"{key}: no successful backup found")

        archiver = archive_status_from_cluster(namespace, name)
        if archiver.failed:
            bad.extend(archiver.details)
        details.extend(archiver.details)

    return CheckResult(
        "cnpg-backups",
        "pass" if not bad else "fail",
        "all CNPG backups and WAL archiving healthy" if not bad else f"{len(bad)} CNPG backup/WAL issues",
        bad or details,
    )


def cnpg_cluster_hibernated(cluster: dict[str, Any]) -> bool:
    annotations = cluster.get("metadata", {}).get("annotations", {})
    if annotations.get(HIBERNATION_ANNOTATION) == "on":
        return True

    conditions = cluster.get("status", {}).get("conditions", [])
    return any(
        condition.get("type") == HIBERNATION_ANNOTATION and condition.get("status") == "True"
        for condition in conditions
    )


def archive_status_from_cluster(namespace: str, name: str) -> CheckResult:
    result = run(["kubectl", "cnpg", "status", "-n", namespace, name])
    if result.returncode != 0:
        return CheckResult("cnpg-wal", "fail", "cnpg status failed", [f"{namespace}/{name}: {result.stderr.strip()}"])
    waiting = None
    failing = False
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Working WAL archiving:"):
            failing = "Failing" in stripped
        if stripped.startswith("WALs waiting to be archived:"):
            waiting = stripped.rsplit(":", 1)[-1].strip()
    details = []
    if failing:
        details.append(f"{namespace}/{name}: WAL archiving failing")
    if waiting and waiting != "0":
        details.append(f"{namespace}/{name}: {waiting} WALs waiting")
    return CheckResult("cnpg-wal", "fail" if details else "pass", "WAL archiving checked", details)


def age_seconds(timestamp: str) -> float:
    parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    return (datetime.now(UTC) - parsed).total_seconds()


def grafana_alerts() -> CheckResult:
    query = urllib.parse.quote(ALERT_QUERY)
    payload = remote_get(PROMETHEUS_QUERY_URL.format(query=query))
    alerts = payload.get("data", {}).get("result", [])
    details = []
    for alert in alerts:
        metric = alert.get("metric", {})
        resource = alert_resource(metric)
        namespace = metric.get("namespace", "-")
        details.append(f"{metric.get('alertname', 'unknown')}: {namespace}/{resource}")
    return CheckResult(
        "grafana-alerts",
        "pass" if not details else "fail",
        "no firing non-Watchdog alerts" if not details else f"{len(details)} firing non-Watchdog alerts",
        details,
    )


def alertmanager_summary() -> CheckResult:
    alerts = remote_get(ALERTMANAGER_URL)
    active = [
        alert
        for alert in alerts
        if alert.get("status", {}).get("state") == "active"
        and alert.get("labels", {}).get("alertname") != "Watchdog"
    ]
    details = []
    for alert in active:
        labels = alert.get("labels", {})
        resource = alert_resource(labels)
        details.append(f"{labels.get('alertname', 'unknown')}: {labels.get('namespace', '-')}/{resource}")
    return CheckResult(
        "alertmanager",
        "pass" if not active else "fail",
        "no active non-Watchdog Alertmanager alerts" if not active else f"{len(active)} active non-Watchdog alerts",
        details,
    )


def alert_resource(labels: dict[str, Any]) -> str:
    return (
        labels.get("deployment")
        or labels.get("statefulset")
        or labels.get("daemonset")
        or labels.get("job_name")
        or labels.get("pod")
        or labels.get("service")
        or "-"
    )


def run_edge_smoke() -> CheckResult:
    result = run(["task", "kubernetes:edge-smoke"])
    output = "\n".join(part for part in [result.stdout.strip(), result.stderr.strip()] if part)
    return CheckResult(
        "edge-smoke",
        "pass" if result.returncode == 0 else "fail",
        "edge smoke passed" if result.returncode == 0 else "edge smoke failed",
        output.splitlines()[-20:],
    )


def run_log_noise(period: str, top: str) -> CheckResult:
    result = run(["task", "kubernetes:log-noise", f"PERIOD={period}", f"TOP={top}"])
    output = "\n".join(part for part in [result.stdout.strip(), result.stderr.strip()] if part)
    return CheckResult(
        "log-noise",
        "pass" if result.returncode == 0 else "fail",
        "log-noise query completed" if result.returncode == 0 else "log-noise query failed",
        output.splitlines()[-30:],
    )


def notify(results: list[CheckResult]) -> None:
    failures = [result for result in results if result.failed]
    if not failures:
        return
    title = "Cluster health: action needed"
    message = "; ".join(f"{result.name}: {result.summary}" for result in failures)
    run([os.path.join("scripts", "notify"), "--status", "failure", "--title", title, "--message", message])


def print_text(results: list[CheckResult]) -> None:
    print(f"Collected at {datetime.now(UTC).strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print()
    for result in results:
        marker = "PASS" if result.status == "pass" else "FAIL"
        print(f"[{marker}] {result.name}: {result.summary}")
        for detail in result.details:
            print(f"  - {detail}")
        print()


def selected_checks(args: argparse.Namespace) -> list[CheckResult]:
    if args.command == "cnpg-health":
        return [cnpg_clusters()]
    if args.command == "cnpg-backups":
        return [cnpg_backups()]
    if args.command == "grafana-alerts":
        return [grafana_alerts(), alertmanager_summary()]
    if args.command == "morning-check":
        results = [
            check_nodes(),
            check_kube_vip(),
            check_cilium(),
            check_not_ready_pods(),
            check_deployments(),
            cnpg_clusters(),
            cnpg_backups(),
            grafana_alerts(),
            alertmanager_summary(),
            run_edge_smoke(),
        ]
        if args.log_noise:
            results.append(run_log_noise(args.period, args.top))
        return results
    return [
        check_nodes(),
        check_kube_vip(),
        check_cilium(),
        check_not_ready_pods(),
        check_deployments(),
        cnpg_clusters(),
        grafana_alerts(),
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["health", "cnpg-health", "cnpg-backups", "grafana-alerts", "morning-check"])
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    parser.add_argument("--notify", action="store_true", help="Send phone notification when failures are found")
    parser.add_argument("--log-noise", action="store_true", help="Include log-noise in morning-check")
    parser.add_argument("--period", default="1h", help="Log-noise period when --log-noise is used")
    parser.add_argument("--top", default="20", help="Log-noise top count when --log-noise is used")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        results = selected_checks(args)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps([asdict(result) for result in results], indent=2, sort_keys=True))
    else:
        print_text(results)

    if args.notify:
        notify(results)

    return 1 if any(result.failed for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())
