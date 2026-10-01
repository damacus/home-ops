# IronBridge in `dev`

IronBridge has one replica and a `Recreate` update strategy. Its Slack and
Discord gateway connections have no distributed owner election, so overlapping
pods must never forward at the same time. State is in the `ironbridge` database
on the existing `northops-postgres` cluster; this
Deployment has no database PVC.

The readiness probe runs `ironbridge status` inside the image. It opens the
PostgreSQL connection and reads queue and channel state, so a database outage
makes the pod unready. It does not prove that Slack or Discord gateway sessions
are healthy; verify those separately during the controlled live test. Version
0.1.5 selects the TLS crypto provider before connecting, constructs a valid
Discord WebSocket request target, and exits if a worker or gateway task stops,
allowing Kubernetes to restart the bridge. Enable Message Content access on
the Discord application before activating reverse forwarding.

The active manifest uses `BRIDGE_ENABLED=true`,
`BRIDGE_DIRECTION=both`, `BRIDGE_SCOPE=all`, and an empty
`SLACK_CHANNEL_IDS` list. It creates missing public channels on either platform.
Private Discord channels and private threads are excluded from public Slack
forwarding; an explicitly configured private administrator pair is handled
separately. Existing same-name channel collisions remain paused until an
administrator approves each pairing.

Verify fresh human messages in both directions, then replies, edits, files,
reactions and deletions in a controlled channel. Slack messages retain the
author avatar and `Name · via Slack` webhook identity without a source-link
footer. Discord messages use the fixed Slack bridge identity, display the Discord
author avatar, and name the author in the body without a source-link footer.
Slack customization requires `chat:write.customize` and informed member consent;
the installed IronBridge app has been updated with this scope. Source references
remain in hidden Slack message metadata for retry recovery.

Version 0.1.7 recovers missed Slack replies even after the channel cursor has
passed their parent, mirrors a missed Discord thread starter before attaching
replies, and names new Discord threads from the original message. Check mention
suppression and loop prevention,
then restart the pod and verify queued work resumes without duplicate delivery.
Check delivery failures and unresolved removal tasks after activation.

Version 0.1.8 also mirrors Slack “also send to channel” replies into their
original Discord thread and recovers broadcasts silently skipped by older
versions. It does not create a second top-level copy of the reply.

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

## Dashboard and moderation preparation

This change prepares resources only. `DASHBOARD_ENABLED=false` means there is
no web listener. The internal TLS HTTPRoute can therefore return an unavailable
backend until a reviewed release and dashboard activation. It references the
existing `traefik-internal` `websecure` listener and wildcard certificate.
The ClusterIP Service has no external address. The ingress NetworkPolicy allows
only Traefik pods in `network` on TCP 8080; database, Slack, Discord and Jev
outbound traffic remain available. Check policy enforcement and Gateway TLS
live during the authorised rollout; rendering alone does not prove either.
Read-only inspection on 2026-09-30 found both running Traefik pods in `network`
carry `app.kubernetes.io/name=traefik`, matching the policy selector. No policy
was applied and ingress denial has not yet been demonstrated live.

`ironbridge-forward-auth` in `dev` uses the existing OAuth2 Proxy and forwards
its ID token in `Authorization`. The application independently validates the
signature, issuer, audience and membership. It must ignore proxy identity
headers as an authorisation source. OAuth2 Proxy already uses
`--set-authorization-header=true`. No native callback or application OAuth
client secret is required. All POSTs require exact Origin, signed subject-bound
CSRF token and a `__Host-` Secure/HttpOnly/SameSite=Strict cookie. Test these with
the final application build before enabling the listener.

### Identity and secret enrolment gate

Review this table with Dan before adding credentials or membership. Do not
infer identity from names or email addresses.

| Setting | Reviewed source |
| --- | --- |
| `DASHBOARD_OIDC_ISSUER` | `https://zitadel.damacus.io` |
| `DASHBOARD_PUBLIC_ORIGIN` | `https://ironbridge.ironstone.casa` |
| `DASHBOARD_MEMBER_GROUP` | Dedicated `ironbridge` claim/group |
| `DASHBOARD_OIDC_AUDIENCE` | Client ID used by the existing OAuth2 Proxy |
| `DASHBOARD_JWKS_URL` | Verified issuer discovery JWKS HTTPS URI on the issuer host |
| `DASHBOARD_ADMIN_SUBJECT` | Dan's verified immutable Zitadel `sub` |
| `DASHBOARD_CSRF_SECRET` | Separately generated random secret of at least 32 bytes |

Use only `op` CLI for credential operations; never print values in logs or task
reports. No values are needed to review these manifests. The separate
`prepare-secrets/` Kustomization is deliberately absent from Flux. Its
`ironbridge-dashboard` ExternalSecret refers to a new item with the three
JWKS/admin-subject/CSRF fields above. Audience is read directly from the same
`zitadel-oauth2-proxy-oidc` item, property `client_id`, used by OAuth2 Proxy. Its `ironbridge-moderation` ExternalSecret
reuses existing item `JEV_API_KEY`, property `credential`, as `JEV_API_KEY`.
Neither adds fields to the current operational `ironbridge` ExternalSecret.
The Deployment's optional references let the existing bridge continue when
these secrets do not exist. When enabled, incomplete dashboard configuration
must fail startup. Missing Jev key must leave durable pending work without
calling Jev. Do not add a fictitious `MODERATION_ENABLED` setting.

After explicit approval, enrol only Dan as administrator and reviewed members
in `ironbridge`; confirm the signed token has the expected group claim. A
member may view public status only. Cases, preview and actions are admin only.
Validate non-member denial and member denial of every admin endpoint.
Only after verified fields exist and a new reviewed image is published should
an activation PR add the standalone ExternalSecrets to the app Kustomization,
update the image to its immutable digest, and change `DASHBOARD_ENABLED` to
`true`. Review the rendered diff before merging. Flux reconciliation and
activation need separate approval. Preserve one replica, Recreate, CNPG TLS,
read-only filesystem and scratch storage. Keep the current digest until then.

### Slack permission and shadow acceptance gate

Review the Slack app manifest and add `emoji:read` to bot scopes if absent.
Reinstall the app into the same workspace after reviewing the scope diff.
If reinstall rotates credentials, use `op` to update the existing token item
without exposing the value. Confirm workspace identity, emoji lookup and the
existing channel scopes still work. This is an authorised later operation.
The source release must retain the 0.1.9 approval notification fix; the current
manifest digest alone does not establish source inclusion or published build
provenance. Have the source coordinator verify the fix and release tests.

Begin with `MODERATION_SHADOW=true` and
`MODERATION_NOTIFICATIONS_ENABLED=false`. No history import, automatic
sanctions or private administrator-pair scanning is allowed. Verify public
bridged-channel coverage, seven-day cross-channel context, thirty-day routine
context and ninety-day selected evidence after case closure against source
and database behaviour. Verify stable platform-scoped pseudonyms preserve
speaker/target relationships without matching accounts by name.

Record the observation window, public channel coverage, pending/failed queue
counts and oldest age, successful Jev assessments, error/rate-limit counts,
latency and usage/cost. Set an explicit budget with Dan and compare recorded
usage with the Jev account before alert activation. Validate pending backlog
survives restart and key absence, then drains within an agreed bound when
credentials return. Compare decisions with human review and NorthBot output;
review false positives, omissions and duplicate incidents. Treat readiness as
database evidence only; separately verify both platform gateways. No new
metrics endpoint or alert names are claimed by these manifests. Initially use
the actual application dashboard, structured logs and database inspection;
add monitoring rules only against verified emitted metrics.

Review `/admin/notifications` first. The administrator web inbox defaults on and
works while shadow is true and external notifications are false. It shows new and
urgent findings with case links, read acknowledgement and verified-actor audit.
Case review remains available when inbox presentation is off. Members cannot see
findings, evidence or destination settings.

After Dan accepts shadow evidence, explicitly enable the chosen private
administrator destination in the dashboard. Slack and Discord have independent
switches, both off by default. Select eligible private Slack and Discord channels
independently from the dashboard dropdowns. Prepare choices while switches are
off; saved choices survive restarts. Moving a destination does not change bridge
pairs, channel names or positions. Saving and each dispatch verify current
private channel/guild/administrator/bot access against the exact selected route.
Unavailable discovery retains saved choices; invalid privacy holds delivery.
The UI cannot edit secrets and cannot
bypass `MODERATION_SHADOW` or `MODERATION_NOTIFICATIONS_ENABLED`. Opening the web
inbox or switching a destination alone does not authorise a live rollout.

A separately approved server activation must set shadow false and notifications
true. Test one controlled new urgent finding for each enabled destination. Verify
correct case link, truthful bot identity, no pings, no public content leakage,
audit trail and independent delivery/recovery after restart. Record rollback
results before broadening delivery. A newly enabled route covers new urgent
findings only; historical shadow findings remain in web review and are not
flooded into private channels. Disabling a destination holds previously queued
work for that route. Re-enabling the same route resumes pending work; changing
the target holds the old route and creates a new route for future findings, even
when returning to an earlier channel. Old queued work stays held and message IDs
are never reused across routes.

Original pre-routing `moderation_alerts` records did not store a destination.
Their timestamps, notice keys and retry metadata are retained for audit. The
inbox reports these held records for manual review in the original private
channel; it never guesses a target or replays them. Current cases remain visible.

Rollback server notifications to false first, then disable chosen external UI
switches. Inbox presentation can be disabled separately. Retain evidence and
queued work. These runbook changes preserve the current disabled/shadow defaults,
one replica/Recreate, deployment digest, authentication membership and NorthBot.

### Reviewed NorthBot transition (not applied)

NorthBot remains `PROACTIVE_ENABLED=true`. After the accepted shadow window,
review whether all NorthBot proactive scanning is covered by IronBridge.
If any unbridged channel still needs NorthBot, do not use the global switch;
prepare a separately reviewed source/configuration exclusion for only covered
channels. If every proactive channel is covered and Dan approves the switch,
the following patch is the complete proposed deployment change:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: northbot
  namespace: dev
spec:
  template:
    spec:
      containers:
        - name: northbot
          env:
            - name: PROACTIVE_ENABLED
              value: "false"
```

Apply it through a separate reviewed GitOps change only after shadow acceptance
and approved IronBridge alert delivery. Confirm NorthBot commands and reactive
behaviour still work, only one owner scans each intended channel, and there are
no coverage gaps. If alerts fail or coverage differs, restore the previous
`true` setting through the reviewed rollback and disable IronBridge
notifications until corrected. Do not change either setting during preparation.
