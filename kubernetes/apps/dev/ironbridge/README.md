# IronBridge in `dev`

IronBridge has one replica and a `Recreate` update strategy. Its Slack and
Discord gateway connections have no distributed owner election, so overlapping
pods must never forward at the same time. State is in the `ironbridge` database
on the existing `northops-postgres` cluster; this
Deployment has no database PVC.

The readiness probe runs `ironbridge status` inside the image. It opens the
PostgreSQL connection and reads queue and channel state, so a database outage
makes the pod unready. It does not prove that Slack or Discord gateway sessions
are healthy; verify those separately during the controlled live test.

The manifest starts with `BRIDGE_ENABLED=false`,
`BRIDGE_DIRECTION=slack-to-discord`, `BRIDGE_SCOPE=all`, and an
empty `SLACK_CHANNEL_IDS` list. The image is pinned to the verified Linux
ARM64 `v0.1.0` release digest. Lift the Flux suspension only after the
remaining activation checks are complete.
After the database, secrets, backup and access checks are verified, compare
the full eligible-channel inventory and enable the bridge. It will create
missing Discord channels for eligible public Slack channels. Existing same-name
Discord channels need explicit pairing approval. Verify Slack-to-Discord
messages after activation before considering Discord-to-Slack forwarding.

The `ironbridge` 1Password item must contain dedicated Slack and Discord app
credentials: `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_TEAM_ID`,
`SLACK_ADMIN_CHANNEL_ID`, `DISCORD_BOT_TOKEN`, and `DISCORD_GUILD_ID`. The
`ironbridge-db` item contains a separate random `password`. Neither item may
reuse NorthBot's credentials. The database URL uses the internal
`northops-postgres-rw` Service with verified TLS and the CNPG CA Secret.

The shared cluster keeps NorthBot's database, role, backup ObjectStore and
ScheduledBackup. IronBridge has its own managed role and database. The cluster's
IronBridge-specific `pg_hba` rules admit that role only to `ironbridge` over TLS;
other database connections are rejected before the default authentication rule.
Before activation, verify this with the IronBridge credential against
`ironbridge`, `northbot`, `postgres` and `template1`. As the `ironbridge` owner,
run `REVOKE CONNECT, TEMPORARY ON DATABASE ironbridge FROM PUBLIC;`, then
verify that NorthBot's existing owner and runtime connections still work.
The existing cluster's 30-day RustFS Barman backup policy covers both databases;
check a fresh backup, WAL archive and restore containing `ironbridge` before
enabling the bridge.
