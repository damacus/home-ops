# Loki log alerts

Vector sends Kubernetes container logs to monitoring Loki. These rules complement
VictoriaMetrics alerts for certificates, workloads, databases, backups, node and
volume capacity, Longhorn, Tempo and Home Assistant. They do not replace those
metrics alerts.

## Provisioning

Flux creates `loki-alert-rules` in monitoring. Helm mounts its complete directory
read-only at `/etc/loki/managed-rules`, with `fake/home-ops.yaml` for the default
single tenant. The ruler reads this directory and sends alerts to
`vmalertmanager-vm.monitoring.svc.cluster.local:9093`. ConfigMap directory updates
propagate without a discovery sidecar or a subPath mount. Allow time for Kubernetes
volume refresh and the Loki rule polling interval.

The previous monitoring rule directory had no active groups in the audit. The
OpenEBS ruler retains its existing S3 configuration. This change does not introduce
shared S3 rule publishing or enable the Loki rule management API.

## Alerts and response

| Alert | Condition | Response |
| --- | --- | --- |
| FrigateCameraRepeatedFailures | At least three watchdog crash/no-frame messages for one camera in ten minutes, persisting five minutes | Check camera power/network, RTSP availability and Frigate watchdog logs. Restore the stream before changing codec or restart settings. |
| IronBridgeDeliveryExhausted | A delivery exhausted retries within fifteen minutes | Check IronBridge job history, destination access and provider response. Confirm delivery state before retrying to avoid duplicates. |
| ApplicationStorageWriteFailure | Loki, RustFS, PostgreSQL, Frigate, VolSync or Barman reports a full/read-only filesystem or I/O error within ten minutes | Identify the affected mount, check free space/inodes and node storage health, and verify a subsequent successful write. Capacity alerts are separate early warnings. |

Frigate counts watchdog messages, not every FFmpeg stderr line. Logger formats can
change across upgrades; recheck camera extraction when upgrading Frigate. Transient
reconnects below the threshold do not alert. Delivery and storage conditions use
rolling windows, so notifications remain active until those windows expire.

Warning severity follows the existing Alertmanager quiet-hours route. Critical
storage failures follow its critical route. No raw log message, URL, token, error
body or message content is copied into alert labels or annotations.

## Verification after deployment

1. Confirm the monitoring and OpenEBS HelmReleases and replacement Loki pods are Ready.
2. Confirm `/prometheus/api/v1/rules` on monitoring Loki reports the three rules with healthy evaluation.
3. Confirm Loki has no `loki-sc-rules` container, discovery RBAC or API token mount.
4. Confirm existing log queries work and existing VictoriaMetrics alerts remain healthy.
5. Verify the next real firing alert reaches Alertmanager and the existing notification receiver. Do not inject synthetic production failures.

Notifications depend on the log ingestion path and Loki availability. Metrics-based
monitoring must continue to cover those services when their own logs cannot arrive.
