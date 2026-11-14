# LiteLLM AI and MCP gateway

Use this guide to connect a client, investigate access or cost, and recover the
AI/MCP gateway. The [rollout history](../../../../docs/history/litellm-client-rollout.md)
keeps the original activation and client-cutover sequence.

Configuration reviewed on 14 November 2026: the gateway Flux Kustomizations are
enabled, and LiteLLM uses the Grounded Docs gateway overlay. Check each client's
current configuration before assuming it uses this gateway; live client access
and backup checks were not repeated for this documentation update.

## Access and cost

The private endpoint is `https://litellm.ironstone.casa`; applications use
`http://litellm.dev.svc.cluster.local:4000/v1`. TLS uses the existing internal
Traefik gateway and certificate. There is no public route.

The admin UI is at `https://litellm.ironstone.casa/ui` and uses native Zitadel
OIDC with PKCE. The Zitadel application `litellm` uses the callback
`https://litellm.ironstone.casa/sso/callback`. The `dan.webb@damacus.io`
account (subject `356498976247120897`) is the proxy administrator; other accounts
have no dashboard access. Both database password login and environment/master-key
UI login are disabled. API key authentication remains available for clients.
LiteLLM's free SSO tier permits up to five users. The dedicated Zitadel project
`LiteLLM` requires a project role on authentication, and only the administrator
has a grant. Keep this restriction: LiteLLM creates user records before its
`admin_only` check, so denied accounts could otherwise consume SSO seats.

After an authentication rollout, verify an administrator can complete Zitadel
sign-in and open the dashboard. An account without the project's `admin` grant
must be rejected by Zitadel before returning an authorisation code; verify it
creates no LiteLLM user record. Confirm both `/login` and `/v2/login` reject
passwords (including the master key) with HTTP 403, while authenticated API and
MCP requests still work. Never record credentials or session tokens as evidence.

OpenAI API usage is billed separately from ChatGPT subscriptions. Frigate and
Paperless each have a **$10 USD calendar-month budget** and Mealie has **$5** in
`keys.json`. Paperless generation and embeddings share its budget. Concurrent
requests and delayed accounting can slightly exceed the limit. Exhaustion stops
new AI requests; it must not stop recording, ingestion or ordinary recipe use.
Keep a single gateway replica initially so there is no distributed accounting
dependency. Do not add another replica without configuring shared rate/budget
coordination. Do not reset spend during key reconciliation or rotation.

One wildcard route forwards model names to OpenAI. Explicit deployments also
exist for the v6 family (`gpt-6.1-terra`, `gpt-6.1-sol`, `gpt-6-luna`,
`gpt-6-astra`), `jev-latest` and `smart-router`, an auto-router whose TypeSafe
Jev classifier picks a complexity tier per request. Mealie's key is restricted
to its v6 models plus `gpt-4o-mini-transcribe` for audio transcription; other
app keys have
no model allowlist (`models: []`), so their models can be changed in each app
without editing the gateway. OpenAI account access still applies. Frigate and
Paperless initially use `gpt-4.1-mini`, with `text-embedding-3-small` for
Paperless embeddings.

The `jev-latest` deployment routes TypeSafe AI's Jev decision model through the
gateway (`typesafe/jev-latest`), shadowing the wildcard for that name. Its
credential is the shared `JEV_API_KEY` 1Password item surfaced as
`TYPESAFE_API_KEY`, which also enables LiteLLM's `/typesafe` pass-through to
`api.typesafe.ai`. Jev is billed per input token under the calling key's budget;
there is no output charge. Callers still need a gateway key — no Jev route is
anonymous.

App keys have no MCP grants. The Codex and Claude keys have Home Assistant and
Grafana grants, and only the deliberately nonexistent `__mcp_only__` model, so
they cannot perform model inference. Their existing subscription login remains
unchanged. Home Assistant keeps **all currently exposed read/write tools**.
Grafana uses both `--disable-write` and a dedicated Viewer service account.

The upstream OpenAI key and HA token live only in the gateway. Grafana's Viewer
token lives only in grafana-mcp; LiteLLM holds a separate MCP transport token.
Mealie still stores its restricted gateway key in its provider records because
that is how this version stores provider credentials. This removes upstream
credentials from clients, not every credential from every application.

## Secret inventory

Create or update the following items in the existing `home-ops` vault after
approval. Preserve unrelated fields. Never commit values or print API responses
containing keys.

| Item | Fields |
| --- | --- |
| `litellm` | `openai-api-key`, `master-key`, `salt-key`, `home-assistant-token`, `grafana-service-account-token`, `grafana-mcp-token` |
| `litellm-db` | `password` |
| `litellm` (UI) | `oidc-client-id`, `oidc-client-secret` |
| `rustfs-cnpg-litellm` | `username`, `password` |
| `JEV_API_KEY` (shared item) | `credential` |
| `litellm-mealie`, `litellm-frigate`, `litellm-paperless` | `key` |
| `litellm-codex`, `litellm-claude` | `key` |

Generate independent random `sk-` master/client keys in 1Password. The salt must
remain stable across restarts and database restores. Create an HA long-lived
token on an identity with the existing broad MCP permissions; do not change the
HA integration's exposure settings. The Grafana token must belong to a dedicated
Viewer service account, not the existing interactive administrator.

The database uses two CNPG instances, WAL archiving to the dedicated
`cnpg-litellm` RustFS bucket, daily backups and 30-day retention. Its bucket IAM
identity has no access to other buckets. Preserve the 1Password salt alongside
database recovery; losing it can make encrypted database credentials unusable.

## Clients and configuration changes

Use the endpoint and existing client-specific key in the application's supported
provider settings. Review the current Flux path before changing an overlay;
the [original rollout plan](../../../../docs/history/litellm-client-rollout.md)
records the client-specific prerequisites and rollback considerations.
Preserve spend counters and existing identities when applying key policies
through LiteLLM's supported administration API or UI.

For local agents, inject the key from the secret store into the client's
environment; never put a literal key in its configuration:

```toml
[mcp_servers.litellm]
url = "https://litellm.ironstone.casa/mcp"
bearer_token_env_var = "LITELLM_MCP_KEY"
```

Verify the affected model/MCP operation and the denied-access case after a
change. A healthy gateway is not evidence that every application has cut over.

## Verification and recovery

Use the existing render, schema and security checks, then exercise the pinned
chart in a dedicated namespace on `docker-desktop` with synthetic credentials.
Check authentication, allowed and denied MCP access, key rotation without budget
reset, and provider updates that preserve existing application settings. Never
use production credentials or application documents for local verification.

The gateway deployments are enabled and the client overlays are inactive. Check real
application and MCP connectivity during the approved rollout. Static checks do
not establish live access or backup recovery.

Gateway API ingress on port 4000 permits Traefik and the three application pods.
A separate metrics listener on port 4001 permits only monitoring `vmagent` pods.
During rollout, check that vmagent can scrape port 4001 and an unrelated
monitoring pod cannot connect to either port. Home Assistant MCP uses its private HTTPS route;
verify its certificate and MCP connectivity from the gateway.

Rollback one client by restoring its original Flux path. Restore Mealie's
provider endpoint/key through its API from the secure pre-cutover backup.
Restore Paperless AI overrides if changed; disable AI if the old state had it
disabled. Retain the existing vector index unless deliberately rebuilding it.
Restoring the Frigate base disables the new external GenAI without changing
recordings. Revoke the affected gateway key after the rollback succeeds.
Do not delete the gateway database or backup bucket as part of rollback.

Rotate provider credentials in 1Password and let External Secrets/reloader
refresh the relevant workload. For client rotation, use LiteLLM's key
regeneration API with preserved spend, update that client's 1Password item,
verify the new key and reject the old one. Do not create a fresh budget to
work around exhaustion. For disaster recovery, restore CNPG from the dedicated
ObjectStore to a separate cluster, supply the original salt and test keys and
budgets before directing clients to the recovered gateway.

## MCP service identities

The Codex and Claude keys belong to dedicated non-admin identities
`mcp-codex` and `mcp-claude`, respectively. Provision them as
`internal_user_viewer` without a generated key before applying key policies.
Do not attach these service keys to the interactive proxy administrator.
Preserve their `__mcp_only__` model restriction and remaining MCP grants.
