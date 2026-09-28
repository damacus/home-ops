# NorthBot in home-ops

The desired Deployment runs one NorthBot replica in `dev` with `Recreate` rollout
strategy. It connects to the `northbot` database on the shared
`northops-postgres-rw.dev.svc.cluster.local` PostgreSQL service. An init container
runs `/northbot migrate` with the `northbot_owner` credential before the bot starts.
The bot itself receives only the separate `northbot_runtime` credential. Both
connections verify the PostgreSQL server certificate against the mounted CNPG CA.

The old `northbot` SQLite OpenEBS claim is retained with Flux pruning disabled.
The PostgreSQL Deployment does not mount it. Keep the claim and its SQLite, WAL,
and SHM files together for rollback until the data migration, application
behaviour, and backup restoration have been verified. The node-local claim is
not a backup. Retire it only after the retention decision has been recorded.

The `northbot-refresh` CronJob restarts the Deployment at 04:00 London time so
the mutable Forgejo `main` tag is pulled each day. The Deployment-level Reloader
annotation restarts it when the 1Password-sourced Kubernetes Secret changes.
