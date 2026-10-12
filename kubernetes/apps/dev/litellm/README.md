# LiteLLM AI and MCP gateway

Status: staged. All four new Flux Kustomizations are suspended. Client overlays
are not included in the active application tree. Activation, live credentials
and client changes require the owner's explicit rollout approval.

## Access and cost

The private endpoint is `https://litellm.ironstone.casa`; applications use
`http://litellm.dev.svc.cluster.local:4000/v1`. TLS uses the existing internal
Traefik gateway and certificate. There is no public route or admin UI.

OpenAI API usage is billed separately from ChatGPT subscriptions. Each of
Mealie, Frigate and Paperless has a **$10 USD calendar-month budget** in
`keys.json`. Paperless generation and embeddings share its budget. Concurrent
requests and delayed accounting can slightly exceed the limit. Exhaustion stops
new AI requests; it must not stop recording, ingestion or ordinary recipe use.
Keep a single gateway replica initially so there is no distributed accounting
dependency. Do not add another replica without configuring shared rate/budget
coordination. Do not reset spend during key reconciliation or rotation.

Mealie retains `gpt-4o`, `whisper-1` and `gpt-5`. `home-generation` maps to
`openai/gpt-4.1-mini`; `home-embeddings` maps to
`openai/text-embedding-3-small`. There is no wildcard model or fallback provider.

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
   and verifies each endpoint update. Unknown models or custom headers stop
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

Local verification on 12 October 2026:

- Five provisioning/migration unit tests and five disposable gateway integration
  tests passed, including embeddings, HA-style read/write tool calls, denied
  application MCP calls, Grafana write-tool exclusion, budgets and revocation.
- The real provisioning script created and then updated a dummy key successfully.
- All three client overlays and both new HelmReleases rendered against
  app-template 5.2.1. The running Frigate 0.18 parser accepted the staged config.
- Flux validation passed (192 resources; four intentionally suspended parents).
  YAML lint and rendered schema validation passed.
- All three security baseline checks passed on the explicitly rendered new
  gateway workloads. RustFS IAM policy checks passed. The whole-repository
  report still has three negative baseline checks on other workloads; the
  wider posture scan is informational and is not a clean bill of health.
- The disposable database recorded 28 requests with zero stored prompt or
  response bodies. No real OpenAI requests or live writes were made.

No production service, credential or local MCP client has been changed.
Production connectivity, application behaviour, secret rotation and backup
restoration remain rollout acceptance checks. GitHub CI has not run yet.

Run `task flux:flate-test`, `task k8s:yayamlls`, and the Python tests for key
provisioning and Mealie migration. The suspended HelmReleases need explicit
`helm template` checks because Flate skips suspended parents. The one-line
render diagnostic suppression does not suppress their YAML schemas. Render
each rollout directory with `kubectl kustomize`, then validate its Helm values
against app-template 5.2.1. Run the existing Mondoo manifest policies on output.

`tests/test_litellm_gateway_live.py` is opt-in and rejects non-localhost URLs.
It needs a disposable LiteLLM/PostgreSQL deployment configured with mocked
model responses and dummy credentials, never the production gateway.

The reproducible fixture is `tests/fixtures/litellm/compose.yaml`. Start it with
`docker compose -f tests/fixtures/litellm/compose.yaml up -d --wait`, then run the
live test module with `LITELLM_TEST_URL=http://127.0.0.1:44000`,
`LITELLM_TEST_MASTER_KEY=sk-local-test-master` and `LITELLM_TEST_MCP=1` in its
environment. Finish with `docker compose -f tests/fixtures/litellm/compose.yaml
down --volumes`. The dedicated GitHub workflow runs these same checks.

Check missing/invalid keys, model isolation, no app MCP access, no agent model
access, budget exhaustion, key revocation, missing upstream credentials and
upstream failures. Validate prompt/content omission from persisted spend logs
as well as console output. ServiceMonitor collects metrics without retaining
document contents. Runtime access and actual backup restoration require the
approved rollout; static rendering does not prove them.

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
