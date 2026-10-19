# UniFi MCP through LiteLLM

Staged: the Flux Kustomization is suspended. Network and Protect are independent
controllers and ClusterIP services in `dev`; Access is omitted. Upstream release
images 0.39.0 and 0.9.4 are version-pinned. Upstream release workflows build both
linux/arm64 and linux/amd64; registry manifests and startup still need verification.

Traffic: existing authenticated LiteLLM `/mcp` → private ClusterIP `/mcp` → local
UniFi controller. No HTTPRoute, NodePort, cloud relay or additional DNS is needed.
The backend HTTP transport has no caller authentication. NetworkPolicy allows
only LiteLLM pods in `dev` to reach either backend. Host validation remains on.

Global create/update/delete policy gates are false, sensitive fields are redacted,
and the dedicated controller accounts must also be read-only. Confirmation mode
alone is not a human approval boundary. Lazy registration retains upstream
meta-tool discovery without advertising hundreds of tools initially.

## Activation

1. Verify `unifi.ironstone.casa:443` reaches both Network and Protect APIs from
   `dev`, using a trusted certificate. This hostname comes from existing
   Unpoller configuration; confirm Protect is on the same console before rollout.
   Change Protect's host if it lives elsewhere. Do not disable TLS verification.
2. Create dedicated local UniFi service accounts with read-only access to the
   relevant application. Network's full toolset uses local session credentials;
   do not reuse the Unpoller API key or an SSO/MFA account.
3. Store `username` and `password` fields in 1Password items `unifi-network-mcp`
   and `unifi-protect-mcp` in the existing home-ops vault. External Secrets reads
   those fields; no credential belongs in Git or chat.
4. Confirm the versioned GHCR manifests contain linux/arm64, then set
   `kubernetes/apps/dev/unifi-mcp/ks.yaml` `spec.suspend: false` through GitOps.
   Check ExternalSecrets and both deployments are ready in context `ironstone`.
   Keep LiteLLM startup independent so a UniFi outage cannot hold up other MCPs.
5. Reconcile the Codex and Claude policies using the existing
   `scripts/litellm_keys.py` with secrets injected by `op run`. Preserve their
   existing MCP grants, user identities and `__mcp_only__` model restriction.
   Application keys remain without MCP grants. Config aliases are registered by
   this change; they are unavailable until the staged backends start.
6. Complete the live verification below before treating the integration as ready.
   Existing clients keep `https://litellm.ironstone.casa/mcp` and their own keys.

## Verification

Run repository YAML/render/schema/security checks and existing LiteLLM key tests.
Static checks do not establish live access. After activation verify:

- Codex and Claude keys discover both aliases, list Network devices and Protect
  cameras, and perform one harmless read through each server.
- Anonymous gateway calls fail; Mealie, Frigate and Paperless keys cannot discover
  or invoke either UniFi server. Their model inference continues to work.
- Mutating tools are absent or rejected, including through lazy execute/batch
  dispatch. Inspect registered policy before testing; do not use a real device
  reboot or deletion as a denial probe.
- LiteLLM pods can connect to backend ports 3000/3001; an unrelated pod in `dev`
  and one in another namespace cannot. Validate the rendered pod selectors match
  the NetworkPolicy, and reject unexpected Host headers.
- Restart both deployments and confirm reconnection without credential output.

Local validation may lack task/mise/yayamlls/Helm. CI must complete rendered
schema and security checks before merge. Image pull, controller login, live
network policy enforcement and gateway grants are rollout checks.

Rollback: remove only `unifi_network` and `unifi_protect` grants using the key
policy reconciler, remove those two LiteLLM aliases, and suspend the UniFi Flux
Kustomization. Suspension stops reconciliation but does not stop running pods;
scale both UniFi controllers to zero through a reviewed Git change to shut down.
Preserve all other gateway services, keys and database state.
