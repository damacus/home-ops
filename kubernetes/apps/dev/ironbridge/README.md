# IronBridge

IronBridge connects Slack and Discord, with a private administrator dashboard
and shadow moderation. Use this guide to check delivery, diagnose access or
recover after an upgrade. The [rollout history](../../../../docs/history/ironbridge-rollout.md)
keeps the release changes and detailed acceptance notes.

## What is configured

Repository configuration checked on 14 November 2026: the
[Deployment](app/deployment.yaml) pins 0.3.1, runs one replica with `Recreate`,
enables both bridge directions and the dashboard, and keeps moderation in
shadow mode with external notifications disabled. These are declared settings;
live delivery and access checks were not repeated for this guide.

The dashboard is <https://ironbridge.ironstone.casa>. State lives in the
`ironbridge` database on `northops-postgres`, not in a Deployment PVC.
Keep one replica: overlapping gateway owners can forward duplicate messages.

## Check a broken bridge

```console
kubectl --context ironstone -n dev get deployment ironbridge
kubectl --context ironstone -n dev get pods -l app=ironbridge
kubectl --context ironstone -n dev logs deploy/ironbridge --tail=100
kubectl --context ironstone -n dev get externalsecret ironbridge ironbridge-dashboard ironbridge-moderation
```

Readiness runs `ironbridge task ready`. It checks PostgreSQL and the enabled
dashboard's local HTTP endpoint. It doesn't establish Slack or Discord health:
check gateway logs and a controlled message in each direction. The old bare
`ironbridge ready` command is wrong for the Loco releases.

For missing channels, inspect pairing approval in the dashboard. Same-name
collisions stay paused until approved. Public channels may be created
automatically; private channels/threads are excluded from public forwarding.
Check the Discord application's Message Content access for reverse-forwarding faults.

Inspect failed deliveries and pending work before restarting. The PostgreSQL
queue should survive replacement and drain afterwards. Check replies, edits,
attachments, reactions and deletions separately when the fault affects them.
Use controlled channels; don't copy message contents or tokens into reports.

## Commands and credentials

`/poll` opens a Slack editor; votes persist in PostgreSQL and polls aren't
mirrored to Discord. Check command definitions and the installed `commands`
scope if it doesn't open. `/gif` needs `GIPHY_API_KEY`; this deployment doesn't
map that key, so its absence isn't a bridge outage.

Credentials come from the `ironbridge`, `ironbridge-db` and
`ironbridge-dashboard` 1Password items. Optional moderation uses `JEV_API_KEY`.
Inspect ExternalSecret status without printing values; use `op` for credential
operations. Preserve NorthBot's separate credentials.

The database connection uses verified TLS and the CNPG CA. Its role must reach
`ironbridge` and be denied access to `northbot`, `postgres` and `template1`.
Shared-cluster backups need restore evidence for IronBridge data as well.

## Dashboard access

Traefik and OAuth2 Proxy forward a signed ID token. IronBridge validates its
issuer, signature and audience. The verified administrator subject gets admin
access; the dedicated `ironbridge` member claim allows public status only.

Compare issuer, audience, JWKS and group claims with the
[secret wiring](app/dashboard.yaml) for access failures. POSTs also need exact
Origin, a subject-bound CSRF token and the secure cookie. Don't disable those
checks to make an error disappear. Verify non-member denial and member denial
of admin endpoints after access changes.

## Moderation and notification controls

Shadow mode keeps findings in the private web inbox. External Slack and Discord
destinations have independent switches; the UI cannot override server shadow
or notification settings. Selecting a destination does not enable delivery.

Before activation, review the observation window, coverage, queue age, assessment
errors and cost with the owner. Verify actual administrator/bot access to each
eligible private destination. Historical findings must not be replayed into
newly enabled channels. The
[acceptance history](../../../../docs/history/ironbridge-rollout.md#slack-permission-and-shadow-acceptance-gate)
explains the evidence and held-delivery behaviour.

NorthBot is separate. Don't disable its proactive scanning until coverage is
reviewed and the transition approved.

## Upgrades and recovery

Check the released image, required secrets and a restorable database backup.
Preserve one replica, `Recreate`, TLS and the read-only filesystem. Inspect
startup migrations, readiness and queue draining, then both gateway connections.

The 0.3.0 Loco migration moved queues to `pg_loco_queue` and dropped the old
tables. Reverting the image alone cannot undo it. A reversal needs the
pre-upgrade database backup and a compatible image; see the
[migration history](../../../../docs/history/ironbridge-rollout.md#version-030-loco-migration).

For notification rollback, disable server notifications first, then external
destinations. Keep evidence, held deliveries and database state.
