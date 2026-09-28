# IronBridge in `dev`

IronBridge has one replica and a `Recreate` update strategy. Its Slack and
Discord gateway connections have no distributed owner election, so overlapping
pods must never forward at the same time. State is in `northops-pg`; this
Deployment has no database PVC.

The readiness probe runs `ironbridge status` inside the image. It opens the
PostgreSQL connection and reads queue and channel state, so a database outage
makes the pod unready. It does not prove that Slack or Discord gateway sessions
are healthy; verify those separately during the controlled live test.

The manifest starts with `BRIDGE_ENABLED=false`, `BRIDGE_SCOPE=channels`, and an
empty `SLACK_CHANNEL_IDS` list. Replace the image's all-zero digest with the
verified Linux ARM64 release digest and lift the Flux suspension before
reconciling this Kustomization.
After the database, secrets, backup and restore are verified, set a controlled
Slack channel ID list and enable the bridge. Switch to `BRIDGE_SCOPE=all` only
after the controlled test and eligible-channel inventory pass.

The `ironbridge` 1Password item must contain dedicated Slack and Discord app
credentials: `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_TEAM_ID`,
`SLACK_ADMIN_CHANNEL_ID`, `DISCORD_BOT_TOKEN`, and `DISCORD_GUILD_ID`. The
`ironbridge-db` item contains a separate random `password`. Neither item may
reuse NorthBot's credentials. The database URL uses the internal
`northops-pg-rw` Service and TLS.
