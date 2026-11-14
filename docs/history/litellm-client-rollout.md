---
doc_type: history
description: Original gateway and application-provider cutover plan.
---

# LiteLLM gateway and client rollout

Historical activation plan. It records the proposed sequence and approval at
the time, not the current state of each client or permission to repeat a cutover.
Read the [current gateway guide](../../kubernetes/apps/dev/litellm/README.md) first.

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
4. Review the client policies in `keys.json` and apply them through LiteLLM's
   supported key-management API or administration UI. Retrieve credentials from
   1Password; do not expose master or client keys in command arguments, logs or
   shell history. Preserve spend counters and existing client identities.
5. Verify model requests and MCP allow/deny cases before client cutover. For HA,
   read state, change a reversible test entity and restore its original state.
   For Grafana, read a dashboard and query data; verify write tools are absent.
6. **Mealie:** configure the gateway endpoint, key and existing model IDs through
   Mealie's supported provider settings/API for each group. Preserve provider
   selection and review custom headers before changing an existing provider.
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
