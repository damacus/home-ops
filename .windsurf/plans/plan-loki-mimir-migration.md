# Loki Fix & Mimir Migration Plan

## Executive Summary

This plan addresses:

1. **Immediate**: Fix Loki crash loop (missing `delete-request-store` config)
2. **Short-term**: Add Mimir as metrics backend alongside KPS
3. **Medium-term**: Migrate dashboards/alerting to Mimir
4. **Long-term**: Remove kube-prometheus-stack (KPS)

## Current State Analysis

### Loki Status: CrashLoopBackOff

**Root Cause**: Configuration error in Loki v6.49.0

```text
CONFIG ERROR: invalid compactor config: compactor.delete-request-store should be configured when retention is enabled
```

**Affected Pods**:

- `loki-backend-0` - CrashLoopBackOff (287 restarts)
- `loki-write-0` - CrashLoopBackOff (287 restarts)
- `loki-read-*` - CrashLoopBackOff (287 restarts)

**Alloy Status**: Blocked waiting for Loki dependency

### Current KPS Setup

- **Prometheus**: 14-day retention, 70GB storage, openebs-hostpath
- **Alertmanager**: Pushover notifications, heartbeat webhooks
- **Node Exporter**: Running on all nodes
- **Kube State Metrics**: Full pod/deployment/PVC labels
- **Grafana**: Separate HelmRelease, uses Prometheus as default datasource

### Storage Backend

- **MinIO**: S3-compatible storage at `minio.storage.svc.cluster.local:9000`
- **Buckets**: `loki` bucket configured for Loki
- **Credentials**: Stored in 1Password, accessed via ExternalSecret

---

## PR Strategy (4 PRs)

### PR 1: Fix Loki Installation
**Priority**: Critical
**Estimated Effort**: Small

**Changes**:
1. Add `delete_request_store` configuration to compactor
2. Point delete request store to S3 (same as chunks)

**File**: `kubernetes/apps/monitoring/loki/app/helmrelease.yaml`

```yaml
loki:
  compactor:
    working_directory: /var/loki/compactor
    retention_enabled: true
    retention_delete_delay: 2h
    retention_delete_worker_count: 150
    delete_request_store: s3  # ADD THIS
```

**Validation**:
- [ ] Loki pods reach Running state
- [ ] Alloy DaemonSet deploys successfully
- [ ] Logs visible in Grafana via Loki datasource

---

### PR 2: Add Mimir Alongside KPS
**Priority**: High
**Estimated Effort**: Medium

**New Files**:
```
kubernetes/apps/monitoring/mimir/
├── app/
│   ├── helmrelease.yaml
│   ├── externalsecret.yaml
│   └── kustomization.yaml
└── ks.yaml
```

**Mimir Configuration** (Monolithic mode for home lab):
- Single replica deployment
- S3 storage (MinIO) for blocks, ruler, alertmanager
- ServiceMonitor enabled
- Remote write endpoint exposed

**Prometheus Remote Write**:
- Configure KPS Prometheus to remote_write to Mimir
- Dual-write period for validation

**Grafana Updates**:
- Add Mimir as secondary datasource
- Keep Prometheus as default initially

**MinIO Bucket Setup**:
- Create `mimir-blocks` bucket
- Create `mimir-ruler` bucket
- Create `mimir-alertmanager` bucket

**Validation**:
- [ ] Mimir pods healthy
- [ ] Metrics flowing via remote_write
- [ ] Mimir datasource queryable in Grafana

---

### PR 3: Migrate Dashboards & Alerting to Mimir
**Priority**: Medium
**Estimated Effort**: Medium

**Changes**:
1. Update Grafana datasource to use Mimir as default
2. Migrate PrometheusRules to Mimir ruler
3. Configure Mimir alertmanager (or keep using KPS alertmanager)
4. Update dashboard datasource references

**Validation**:
- [ ] All dashboards render correctly with Mimir
- [ ] Alerts firing correctly from Mimir
- [ ] Historical data accessible

---

### PR 4: Remove KPS
**Priority**: Low (after validation period)
**Estimated Effort**: Small

**Changes**:
1. Remove `kube-prometheus-stack` from kustomization
2. Keep `prometheus-operator-crds` (needed for ServiceMonitors)
3. Keep node-exporter and kube-state-metrics (can be standalone)
4. Clean up PVCs

**Validation**:
- [ ] All monitoring continues working
- [ ] No orphaned resources
- [ ] Storage reclaimed

---

## Architecture Comparison

### Current (KPS)
```
┌─────────────┐     ┌──────────────┐     ┌─────────┐
│ ServiceMon  │────▶│  Prometheus  │────▶│ Grafana │
│ PodMonitor  │     │  (scrape)    │     │         │
└─────────────┘     └──────────────┘     └─────────┘
                           │
                    ┌──────┴──────┐
                    │ Alertmanager│
                    └─────────────┘
```

### Target (Mimir + Alloy)
```
┌─────────────┐     ┌──────────────┐     ┌─────────┐
│ ServiceMon  │────▶│    Alloy     │────▶│  Mimir  │────▶│ Grafana │
│ PodMonitor  │     │  (scrape)    │     │ (store) │     │         │
└─────────────┘     └──────────────┘     └─────────┘     └─────────┘
                                               │
                                        ┌──────┴──────┐
                                        │ Alertmanager│
                                        └─────────────┘

┌─────────────┐     ┌──────────────┐     ┌─────────┐
│   Pods      │────▶│    Alloy     │────▶│  Loki   │────▶│ Grafana │
│  (logs)     │     │ (DaemonSet)  │     │ (store) │     │         │
└─────────────┘     └──────────────┘     └─────────┘     └─────────┘
```

---

## Migration Tools

### Prometheus to Mimir Migration
1. **Remote Write**: Configure Prometheus to write to both local TSDB and Mimir
2. **mimirtool**: Can be used to analyze and migrate rules
3. **Grafana**: Update datasource URLs

### Commands
```bash
# Analyze Prometheus rules for Mimir compatibility
mimirtool rules lint <rules-file>

# Check Mimir cluster health
curl http://mimir:9009/ready

# Query Mimir
curl 'http://mimir:9009/prometheus/api/v1/query?query=up'
```

---

## Risk Mitigation

1. **Dual-write period**: Run both Prometheus and Mimir for 1-2 weeks
2. **Rollback plan**: KPS remains functional until PR 4
3. **Incremental migration**: Each PR is independently deployable
4. **Monitoring**: Use existing Prometheus to monitor Mimir initially

---

## Timeline Estimate

| PR | Description        | Effort  | Dependencies                  |
|----|--------------------|---------|-------------------------------|
| 1  | Fix Loki           | 1 hour  | None                          |
| 2  | Add Mimir          | 4 hours | PR 1 (for full observability) |
| 3  | Migrate dashboards | 2 hours | PR 2                          |
| 4  | Remove KPS         | 1 hour  | PR 3 + validation period      |

**Total**: ~8 hours + 1-2 week validation period

---

## Next Steps

1. [ ] Implement PR 1 (Loki fix) - **START HERE**
2. [ ] Create MinIO buckets for Mimir
3. [ ] Implement PR 2 (Add Mimir)
4. [ ] Test dual-write configuration
5. [ ] Implement PR 3 (Migration)
6. [ ] Validation period
7. [ ] Implement PR 4 (Remove KPS)
