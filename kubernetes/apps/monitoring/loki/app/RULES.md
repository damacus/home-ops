# Loki log alerts

Vector sends Kubernetes container logs to monitoring Loki. These rules complement
VictoriaMetrics alerts for certificates, workloads, databases, backups, node and
volume capacity, Longhorn, Tempo and Home Assistant. They do not replace those
metrics alerts.

## Provisioning

Flux creates `loki-alert-rules` in monitoring with the `loki_rule` label.
The Rust watcher discovers labelled ConfigMaps across namespaces and writes unique
filenames into `/rules/fake`. The local ruler reads `/rules` and sends alerts to
`vmalertmanager-vm.monitoring.svc.cluster.local:9093`. Updates and deletions flow
through the watcher. The three alert thresholds and Alertmanager routes are unchanged.

Both Loki installations use GitOps-managed ClusterRoles granting only `get`,
`list` and `watch` on ConfigMaps. The API token remains required by each watcher.
Labels filter discovery behaviour; RBAC permits reading all ConfigMaps, so those
must contain no confidential values. Neither role grants Secret access.

The watcher image requires the ownership-state layout fix: tracking JSON belongs
in a private subdirectory, which Loki skips, rather than alongside rule files.
Version 0.2.5 is a release dependency; do not merge until that image is published
and verified. The isolated test supports an explicit local image override solely
for validating the unreleased fix.

OpenEBS retains its S3 ruler storage and `/rules` watcher output. Local watcher
files are not automatically uploaded to S3. Investigate that existing disconnect
separately; this change neither migrates nor overwrites stored S3 rules.

## Rollout and rollback

Record the monitoring rule inventory and OpenEBS S3 rule inventory before merging.
Deploy through Flux after the watcher release is available. Compare inventories,
including the three new monitoring alerts, and verify healthy evaluation.
Roll back through a Git revert if discovery or evaluation regresses. Preserve
rule ConfigMaps and all S3 contents. Do not reconcile Flux manually as part of
publication.

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
3. Confirm both `loki-sc-rules` containers are present and both service accounts can read ConfigMaps but cannot read Secrets.
4. Confirm existing log queries work and existing VictoriaMetrics alerts remain healthy.
5. Verify the next real firing alert reaches Alertmanager and the existing notification receiver. Do not inject synthetic production failures.

Notifications depend on the log ingestion path and Loki availability. Metrics-based
monitoring must continue to cover those services when their own logs cannot arrive.
