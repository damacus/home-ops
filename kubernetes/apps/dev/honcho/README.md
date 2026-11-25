# Honcho

Honcho runs in `dev` as a private API and background memory worker. The pod
runs upstream migrations before either container starts. CloudNativePG stores
messages, memories and vectors in the dedicated `honcho-db` cluster. PostgreSQL
replication provides availability. Barman Cloud archives WAL continuously and
takes a base backup daily at 03:40 UTC. The dedicated RustFS bucket
`cnpg-honcho` has a 30-day recovery window.

## Provision credentials before reconciliation

Create these items in the existing `home-ops` 1Password vault. External Secrets
syncs them into `dev`.

| Item | Field | Value |
| --- | --- | --- |
| `honcho-db` | `password` | Random PostgreSQL password |
| `honcho` | `jwt-secret` | Independent signing secret, at least 32 random bytes |
| `litellm-honcho` | `key` | Dedicated LiteLLM virtual key using the Honcho policy in [keys.json](../litellm/keys.json) |
| `rustfs-cnpg-honcho` | `username`, `password` | Dedicated RustFS access key and secret key |

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

## Check backups and restore

When enabling backups on an existing cluster, wait for the database rollout
and check that continuous archiving is healthy before starting the first
backup. The schedule runs automatically at the next daily slot.

```sh
kubectl -n dev wait --for=condition=ContinuousArchiving cluster/honcho-db --timeout=10m
kubectl cnpg backup -n dev honcho-db --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io
kubectl -n dev get scheduledbackup honcho-db
kubectl -n dev get backups -l cnpg.io/cluster=honcho-db
kubectl -n dev get objectstore honcho-rustfs-store
```

Restore into a separate CloudNativePG cluster using
[`bootstrap.recovery`](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/#restoring-a-cluster-from-an-object-store)
and the `honcho-rustfs-store` ObjectStore with source server name `honcho-db`.
Use a PostgreSQL image with pgvector available. Verify the restored data before
redirecting Honcho. The bucket resides on the shared RustFS storage service.
