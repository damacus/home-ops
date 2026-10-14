# LiteLLM AI and MCP gateway

Status: gateway activation authorised on 13 October 2026. The four gateway
Flux Kustomizations are enabled; dependency checks order bucket provisioning,
database creation and MCP startup before LiteLLM. Client overlays remain staged
until gateway access and backup checks pass.

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

OpenAI API usage is billed separately from ChatGPT subscriptions. Each of
Mealie, Frigate and Paperless has a **$10 USD calendar-month budget** in
`keys.json`. Paperless generation and embeddings share its budget. Concurrent
requests and delayed accounting can slightly exceed the limit. Exhaustion stops
new AI requests; it must not stop recording, ingestion or ordinary recipe use.
Keep a single gateway replica initially so there is no distributed accounting
dependency. Do not add another replica without configuring shared rate/budget
coordination. Do not reset spend during key reconciliation or rotation.

One wildcard route forwards model names to OpenAI. App keys have no model
allowlist (`models: []`), so models can be changed in each app without editing
the gateway. OpenAI account access still applies. Mealie retains its configured
models; Frigate and Paperless initially use `gpt-4.1-mini`, with
`text-embedding-3-small` for Paperless embeddings.

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

## Approved activation sequence

1. Back up Mealie and Paperless databases and preserve current provider settings
   securely. Check that the active storage migrations have finished before
   rolling either application. Rebase the Frigate overlay's config against any
   intervening camera changes; it deliberately replaces the generated config.
2. Provision the listed secrets and identities. Set `suspend: false` in
   `litellm-buckets`, then `litellm-db`, then `grafana-mcp`, then `litellm`.
   Commit these activation changes only after approval. Use the normal GitOps
   reconciliation path with the explicit `ironstone` context.
3. Confirm ExternalSecrets are ready, the database is ready, a backup succeeds,
   both gateway pods are healthy, private DNS resolves and HTTPS is valid.
4. Preview `python3 scripts/litellm_keys.py mealie` (repeat for the other four
   clients). Inject `LITELLM_MASTER_KEY` and the appropriate
   `LITELLM_CLIENT_KEY` using `op run`, then add `--apply`. It creates a missing
   key or updates policy without submitting a spend reset. A failed request
   stops; it never falls back to unauthenticated access. Keep the master key
   out of clients and shell history.
5. Verify model requests and MCP allow/deny cases before client cutover. For HA,
   read state, change a reversible test entity and restore its original state.
   For Grafana, read a dashboard and query data; verify write tools are absent.
6. **Mealie:** inject a group-manager `MEALIE_TOKEN` and its gateway key through
   `op run`. Run `python3 scripts/mealie_litellm.py` to preview, then `--apply`.
   It uses Mealie's supported API, preserves model IDs and provider selection,
   and verifies each endpoint update. Custom headers stop
   the cutover before any write. Repeat with each group if new groups exist.
   Verify text, image and audio operations. Then change the existing Mealie
   Flux Kustomization path to
   `./kubernetes/apps/dev/litellm/rollout/mealie` to remove the obsolete upstream
   OpenAI environment variable and ExternalSecret field.
7. **Frigate:** change its existing Flux Kustomization path to
   `./kubernetes/apps/dev/litellm/rollout/frigate`. It enables completed bird
   event descriptions and review summaries using preview frames; no early
   significant-update requests. Existing local semantic embeddings, detection
   and recording remain unchanged. Verify event descriptions and chat.
8. **Paperless:** review Application Configuration for database overrides of
   `PAPERLESS_AI_*`; clear only conflicting AI overrides after backing them up.
   Change its existing Flux path to
   `./kubernetes/apps/dev/litellm/rollout/paperless`. Whole-archive processing,
   including health, school and finance documents, is approved. The existing
   daily index task builds embeddings; no automatic metadata application is
   introduced. Verify retrieval, source-linked answers and reviewable suggestions.
9. Add `litellm` to each client's Flux `dependsOn` during its cutover. Keep the
   original database and storage dependencies. Observe cost, latency, errors
   and ordinary application health before moving to the next client.
10. Connect local agents, verify the same MCP operations, then remove their
    redundant direct HA/Grafana entries. Do not change their model provider or
    copy the gateway master key into any client configuration.

Example Codex MCP configuration (the environment variable is injected from
1Password when launching the client):

```toml
[mcp_servers.litellm]
url = "https://litellm.ironstone.casa/mcp"
bearer_token_env_var = "LITELLM_MCP_KEY"
```

Claude uses the same HTTP MCP URL with its own gateway key in the Bearer header.
Use the client's environment-variable mechanism rather than a literal token.
Existing cloud-chat clients are outside this rollout.

## Verification and recovery

Use the existing repository manifest checks and the small, offline script tests:

```sh
python3 -m unittest tests/test_litellm_keys.py tests/test_mealie_litellm.py
```

The script tests check budget preservation and safe Mealie provider updates.
They require no containers, credentials or network access. There is no dedicated
gateway integration environment or CI workflow.

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

## Scrypted MCP

Scrypted uses its native OAuth authorization-code flow with PKCE and rotating
refresh tokens. The gateway backend is
`https://scrypted.ironstone.casa/endpoint/scrypted-mcp/public/mcp`.
Do not use the advertised node IP: the TLS certificate covers the hostname.

Only Codex and Claude receive Scrypted grants, with all plugin-exposed tools
as approved by the owner. Application keys retain no MCP grants. Complete
Scrypted OAuth for the gateway identity before expecting tool calls to work;
no short-lived access token is stored in Git or treated as a static API key.

The private Scrypted MCP HTTPRoute covers only the plugin public endpoint
prefix. Its OAuth handler protects MCP calls; the management console keeps
SSO and native login. OAuth discovery and registration must be reachable
without browser SSO for machine clients. No internet-facing route is added.

Validation before gateway rollout: TLS discovery returned HTTP 200 from the
LiteLLM pod and advertised the hostname-based OAuth endpoints. An anonymous
MCP POST returned HTTP 401. Authenticated tool listing, a harmless tool call,
client grant enforcement and refresh-token operation remain rollout checks.

OAuth ownership: the Codex and Claude keys belong to dedicated non-admin
identities `mcp-codex` and `mcp-claude` respectively. Provision these as
`internal_user_viewer` with no generated key before applying key policies.
Complete a separate Scrypted OAuth connection for each identity. Do not attach
these service keys to the interactive proxy administrator. Preserve their
`__mcp_only__` model restriction and existing MCP grants.
