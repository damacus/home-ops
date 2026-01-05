# Hybrid Efficiency Monitoring Stack Migration Plan

**Objective**: Migrate the home lab monitoring stack to a resource-efficient architecture suitable for ARM64 (Raspberry Pi 5) nodes. The goal is to replace "heavy" unified agents (Alloy) and standard Prometheus stacks with lightweight alternatives (VictoriaMetrics, Vector) while maintaining robust logging (Loki) and alerting (Pushover).

**Status**: Planning

## 1. Architecture Overview

### Principles

* Efficiency: Minimize RAM/CPU usage on ARM64 nodes.
* Persistence: Use Local NVMe for hot metrics (VM) and MinIO (S3) for logs (Loki).
* Separation: Decouple metrics (VM) and logs (Loki/Vector) pipelines.

### Components

| Component                    | Role            | Type        | Storage                 | Replacement For           |
|------------------------------|-----------------|-------------|-------------------------|---------------------------|
| **VictoriaMetrics** (Single) | Metrics DB      | StatefulSet | Local NVMe              | Prometheus                |
| **vmagent**                  | Metrics Scraper | DaemonSet   | Buffer to Disk          | Prometheus Agent / Alloy  |
| **Loki** (Single Binary)     | Logs DB         | StatefulSet | MinIO (S3) + NVMe Index | (Existing, verify config) |
| **Vector**                   | Logs Agent      | DaemonSet   | Buffer to Disk          | Promtail / Alloy          |
| **vmalert**                  | Alert Evaluator | Deployment  | N/A                     | Prometheus Rules          |
| **Alertmanager**             | Notification    | Deployment  | N/A                     | (Existing)                |
| **Grafana**                  | Visualization   | Deployment  | PV (Longhorn)           | (Existing)                |

## 2. Migration Phases

### Phase 1: Preparation & Repositories

* Add `victoria-metrics` Helm repository.
* Add `vector` Helm repository.
* Verify MinIO buckets for Loki (`loki-data`, `loki-chunks`) exist and are accessible.

### Phase 2: Metrics Pipeline (VictoriaMetrics)

* Deploy **VictoriaMetrics Single** (Chart: `victoria-metrics-k8s-stack`).
  * Disable `prometheus-node-exporter` (if OS handled) or enable if needed.
  * Disable `grafana` (use existing).
  * Enable `vmagent`, `vmalert`, `alertmanager`.
  * Configure retention: 14 days.
  * Configure storage: Local Path / Longhorn on NVMe.
* Verify `vmagent` is scraping nodes.
* Configure `vmalert` with existing Prometheus rules.
* Configure `Alertmanager` with Pushover secrets.

### Phase 3: Logs Pipeline (Loki + Vector)

* Review existing **Loki** configuration.
  * Ensure "Single Binary" mode (Chart `grafana/loki`).
  * Verify Schema v13.
  * Verify MinIO S3 targets.
* Deploy **Vector** (Chart: `timberio/vector`).
  * Source: Kubernetes logs (`/var/log/pods`), Journald.
  * Transform: Remap pod metadata to labels.
  * Sink: Loki internal service.
* Verify logs in Grafana Explore.

### Phase 4: Visualization (Grafana)

* Update Grafana Datasources (via Helm/GitOps).
  * Add **Prometheus** source -> Pointing to VictoriaMetrics.
  * Verify **Loki** source -> Pointing to Loki.
* Import/Update Dashboards for VictoriaMetrics/Vector compatibility.

### Phase 5: Decommission Legacy

* Remove `kube-prometheus-stack` (Prometheus, old Alertmanager).
* Remove `alloy` (Grafana Agent).
* Verify resource usage drop on nodes.

## 3. Configuration Details

### vmagent

* Scrape Interval: 30s.
* Extra Args: `-remoteWrite.tmpDataPath=/var/lib/vmagent-data` (Disk buffering).

### Vector

* Role: Agent.
* Sources: `kubernetes_logs`, `host_metrics` (optional), `internal_metrics`.
* Sink: `loki` (encoding: json/protobuf).

### Alerting

* Receiver: Pushover.
* Secrets: `ALERTMANAGER_PUSHOVER_TOKEN`, `PUSHOVER_USER_KEY`.

## 4. Verification Steps

1. **Metrics**: Query `up` in Grafana (VM datasource) -> Should see all nodes.
2. **Logs**: Query `{namespace="kube-system"}` in Grafana (Loki datasource).
3. **Alerts**: Trigger a test alert (e.g., Watchdog) -> Receive Pushover notification.
4. **Reboot Test**: Reboot a worker node -> Verify data buffering and recovery.
