# Usage Ledger

Private dashboard: https://ledger.ironstone.casa/

One non-root Rust scratch container writes SQLite on the 5 GiB Longhorn RWO claim. Recreate prevents competing writers. Longhorn default recurring snapshot/backup jobs cover the claim. The private Traefik gateway terminates HTTPS; NetworkPolicy restricts application ingress to Traefik.

The externally provisioned `home/ledger-collector` Secret contains a `token` key. It is mounted read-only and must exist before rollout. Credentials and SQLite data are never committed here. The image is published in the internal Forgejo registry.

The Mac LaunchAgent `io.damacus.usage-ledger.cluster-sync` uploads new and corrected typed observations every minute while the Mac is awake and connected. Its owner-private token and acknowledgement database live in `~/Library/Application Support/UsageLedgerRust/`. Failed uploads remain pending and retry on the next run. The original collector database stays local.

Before restoring a cluster backup, pause the uploader and reconcile its acknowledgement state with the restored database; do not reuse acknowledgements for records absent from the restore. A fresh acknowledgement state can replay an empty database. Do not overwrite the original collector database.

The PVC is excluded from Flux pruning: removing the app from Git preserves the ledger data. Default live jobs are `snapshot` at 00:00 daily (five retained) and `ghtlyin` backup at 01:00 daily (two retained), in group `default`; verify these live schedules before relying on coverage.
