# Honcho

Honcho runs in `dev` as a private API and background memory worker. The pod
runs upstream migrations before either container starts. CloudNativePG stores
messages, memories and vectors in the dedicated `honcho-db` cluster. PostgreSQL
replication provides availability. Off-cluster backups are not configured.

## Provision credentials before reconciliation

Create these items in the existing `home-ops` 1Password vault. External Secrets
syncs them into `dev`.

| Item | Field | Value |
| --- | --- | --- |
| `honcho-db` | `password` | Random PostgreSQL password |
| `honcho` | `jwt-secret` | Independent signing secret, at least 32 random bytes |
| `litellm-honcho` | `key` | Dedicated LiteLLM virtual key using the Honcho policy in [keys.json](../litellm/keys.json) |

The LiteLLM key permits `gpt-5.4-mini` and `text-embedding-3-small`.
LiteLLM forwards these workloads to OpenAI, including conversation content
required for generation and embedding. Replacing the signing secret invalidates
existing JWTs. Issue replacement tokens after the Honcho pod has reloaded.

## Connect a client

In-cluster clients in `dev` use `http://honcho.dev.svc.cluster.local:8000` and
need the pod label `honcho-client: "true"`. For workstation access, use a
localhost port-forward through your authorised Kubernetes context.

```sh
kubectl -n dev port-forward --address 127.0.0.1 svc/honcho 8000:8000
```

Mint an expiring, workspace-scoped JWT from the API container and store it in
your client’s secret store. Use it as the API bearer token. Treat the output
as a credential and keep it out of logs and shell history.

```sh
kubectl -n dev exec deploy/honcho -c api -- \
  /app/.venv/bin/python scripts/generate_jwt.py \
  --workspace my-workspace --expires 7d --print-only
```

## Verify a rollout

Check the `honcho-db` Cluster is Ready and the `honcho` Deployment has both
containers ready. Use a synthetic workspace to check scoped JWT access, message
ingestion, semantic search and chat. Confirm unauthenticated and wrong-workspace
requests return HTTP 401. Check that a labelled pod can reach the API and an
unlabelled pod cannot. For rollback, stop the application reconciliation before
changing the database and preserve its volumes.
