# NorthBot in home-ops

The desired Deployment runs one NorthBot replica in `dev` with `Recreate` rollout
strategy. It connects to the `northbot` database on the shared
`northops-postgres-rw.dev.svc.cluster.local` PostgreSQL service. An init container
runs `/northbot init-db` with the `northbot_owner` credential before the bot starts.
The bot itself receives only the separate `northbot_runtime` credential. Both
connections verify the PostgreSQL server certificate against the mounted CNPG CA.

This is a fresh database. Existing test cases in SQLite are disposable; there
is no data import or SQLite rollback path. The old SQLite claim is not part of
this Deployment. Flux pruning was disabled on that claim, so it remains in the
cluster until it is deleted explicitly after the PostgreSQL report flow works:
`kubectl --context=ironstone -n dev delete pvc northbot`.

The `northbot-refresh` CronJob restarts the Deployment at 04:00 London time so
the mutable Forgejo `main` tag is pulled each day. The Deployment-level Reloader
annotation restarts it when the 1Password-sourced Kubernetes Secret changes.
