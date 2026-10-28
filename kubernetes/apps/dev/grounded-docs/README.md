# Grounded Docs

Status: activation authorised on 28 October 2026. Application and backup Flux
Kustomizations are enabled. The refresh schedule stays suspended until initial
indexing and gateway access have been verified. Context7 remains configured.

Grounded Docs gives private Codex, Claude and cluster/VPN clients a shared index
of Loco, Rails and Rust documentation. Search starts with full-text matching;
there are no embedding credentials or external model calls. Telemetry is disabled.

## Runtime and storage

The app-template 5.3.0 chart runs one pod with `Recreate` updates. Three processes
use the same pinned Grounded Docs 3.4.1 multi-architecture image:

| Process | Port | Role |
| --- | --- | --- |
| worker | 8080 | Owns SQLite, crawls sources, resumes interrupted jobs |
| mcp | 6280 | Read-only MCP tools, forwarding requests to the worker |
| web | 6281 | Management UI/API, forwarding requests to the worker |

Only the worker mounts the 10Gi `grounded-docs-data` PVC at `/data`. The existing
`longhorn` StorageClass provides ext4, two storage replicas and best-effort data
locality; verify these settings before creating the claim. Storage replicas are
not additional SQLite processes. Do not change this claim to RWX/NFS or scale the
application beyond one pod. Flux pruning is disabled for the PVC; the underlying
StorageClass uses `Delete`, so manually deleting the claim can still destroy data.

The worker initially requests 250m CPU/1Gi memory and has a 2Gi memory limit.
Each frontend requests 25m/128Mi and has a 256Mi memory limit. These are starting
allocations, not measured requirements; observe RSS, OOMs and indexing time before
adjusting them. Processes run as UID/GID 1000 with dropped capabilities, a
read-only root filesystem, scratch storage and no Kubernetes API token.

## Access

The management address is `https://grounded-docs.ironstone.casa`. Its HTTPRoute
uses `traefik-internal` and the existing OAuth2 Proxy/Zitadel browser sign-in.
Every UI/API path goes through that sign-in, including WebSockets. No public
route is created. Grounded Docs does not provide its own management authentication.

Agent clients keep `https://litellm.ironstone.casa/mcp` and their existing gateway
keys. The active `gateway/` overlay adds only the `grounded_docs` backend
to the existing LiteLLM app. `litellm/keys.json` includes the Codex/Claude grants;
apply those policies to the existing live keys with the key workflow below. Application keys retain no MCP grants
and agent keys retain their existing grants and `__mcp_only__` restriction.

NetworkPolicy permits Traefik to reach the web port, LiteLLM to reach MCP, and
labelled refresh Jobs in `dev` to reach the worker. Other pod ingress is denied.
The unauthenticated worker API is never exposed through the HTTPRoute.
Application-level scraper restrictions allow only the reviewed documentation
hosts and disable local-file ingestion/private-network crawling. These restrictions
are not a general pod egress firewall.

## Catalogue and refresh

`app/sources.json` is the reviewed source list:

| Library | Version | Source |
| --- | --- | --- |
| loco-guides | current | `https://loco.rs/docs/` |
| loco-api | 1.2.0 | `https://docs.rs/loco-rs/1.2.0/loco_rs/` |
| rails-guides | 8.1.4 | `https://guides.rubyonrails.org/v8.1.4/` |
| rust-book | 1.99.1 | `https://doc.rust-lang.org/1.99.1/book/` |
| rust-reference | 1.99.1 | `https://doc.rust-lang.org/1.99.1/reference/` |
| rust-std | 1.99.1 | `https://doc.rust-lang.org/1.99.1/std/` |

Loco guides follow upstream and must not be presented as immutable 1.2.0 docs.
The API source describes upstream Loco, not MedTracker's patched scheduler fork.
Rust 1.99.1 is the selected documentation release, not a claim about every
project's compiler or minimum supported Rust version. Add other releases as
separate catalogue entries; never silently point a fixed version at moving docs.

The initial crawl is deliberately bounded to 200/500 pages per source and four
links deep, with concurrency two. The standard-library/API corpus may therefore
be partial. Check page counts and retrieval coverage before increasing limits.
The docs.rs sources exclude `*.md` links: crate README links resolve relative
to the generated API documentation and can point to missing translated files.
The rendered README and API pages remain indexed.
The reviewed sources use HTTP fetch mode because their documentation is served
as static HTML or repository content. A future source that needs JavaScript
rendering can select `auto` separately; `auto` renders every HTML page in a browser.
Refresh uses the scrape options stored with each version, so changing catalogue
crawl limits alone does not change an existing version's limits: review and edit
its settings in the UI before re-indexing it.

The CronJob runs Sundays at 03:00 UTC once enabled. `sync.mjs` lists the worker's
catalogue, indexes missing entries, and incrementally refreshes exact existing
versions. It refuses changed source URLs and active jobs, never sends `--replace`,
and fails on command errors. The upstream CLI waits for each job to finish.
The refresh Job has no database mount. A CLI timeout or killed Job does not
necessarily cancel the worker job; inspect the UI before retrying. Kubernetes
prevents overlapping scheduled Jobs, but operators must also avoid concurrent
manual refreshes. A failed refresh preserves completed pages under upstream's
refresh rules; retrying an incomplete initial scrape can rebuild that version.

## Activation after approval

1. Recheck current main, StorageClass settings, Longhorn capacity/health and the
   default backup target. Render again and confirm unrelated apps do not change.
2. Set `grounded-docs-backups.spec.suspend: false` in `ks.yaml` and let GitOps
   create the dedicated Longhorn jobs in `storage`.
3. Set the app Flux Kustomization and `app/helmrelease.yaml` to `suspend: false`.
   Leave the refresh CronJob suspended. Wait for the claim, worker and frontends
   to become ready. Verify the actual volume has two replicas/best-effort locality.
4. Confirm private DNS/TLS and browser sign-in, then seed the catalogue by
   creating a one-off Job from the CronJob using the explicit `ironstone` context:

   ```fish
   rtk kubectl --context=ironstone -n dev create job grounded-docs-seed --from=cronjob/grounded-docs-refresh
   rtk kubectl --context=ironstone -n dev logs -f job/grounded-docs-seed
   ```

5. Check source versions, non-empty page counts and useful answers. Enable the
   weekly schedule by setting its `suspend: false` only after the seed succeeds.
6. Rebase `gateway/config.yaml` against the current LiteLLM config: the staged
   file is a full replacement and must preserve every intervening gateway change.
   Change `litellm/ks.yaml`'s path to
   `./kubernetes/apps/dev/grounded-docs/gateway`. Do not add a second Flux
   Kustomization that manages the same LiteLLM resources. Preserve all existing
   dependencies and add `grounded-docs` to that Kustomization's `dependsOn`.
7. The reviewed `litellm/keys.json` already contains the Grounded Docs grants.
   Use the existing `scripts/litellm_keys.py codex` and `claude` preview/apply
   workflow with secrets injected through `op run`, as documented in the LiteLLM
   README. Do not reset spend, rotate keys or grant application keys MCP access.
8. Verify the allow/deny cases below. Keep Context7 configured until these pass;
   replacing global Context7 instructions/client configuration is a later cutover.

## Acceptance and recovery

After approved rollout, check authenticated Codex/Claude can list/search/read
sources through LiteLLM and cannot invoke scrape/remove tools. Anonymous gateway
requests and application keys must be denied. Anonymous management requests must
require browser sign-in; authenticated UI access and WebSocket updates must work.
Verify unrelated `dev`/monitoring pods cannot reach any application port, LiteLLM
can reach only MCP, and refresh Jobs can reach only the worker. Static checks do
not establish these live access results.

Use representative questions about Loco controllers/workers, Rails associations/
migrations and Rust ownership/standard-library APIs. Confirm returned source URLs
and versions and compare expected pages with indexed page counts. Replace the pod
and verify stored results survive, then run another sync and check unchanged
sources refresh without duplicating library versions. Measure retrieval quality
before adding embeddings; adding them later requires re-indexing existing text.

The PVC explicitly selects only `grounded-docs-snapshot` (00:30 UTC, retain five)
and `grounded-docs-backup` (01:30 UTC, retain seven). Longhorn runs these while
the volume is attached and data has changed. Its default backup target currently
uses the cluster's RustFS service; this is recovery storage, not an independent
off-site disaster copy. Volume snapshots are crash-consistent, not a promise that
every in-flight crawl completed. Never copy only a live `documents.db` without
its journal/WAL using a file-level backup.

Before relying on backups, restore one into a separate Longhorn volume/PVC, run
an isolated worker at the same image version, check SQLite integrity and verify
library counts plus known searches. Do not attach the original and restored
claims to the same worker. Record successful backup/restore timestamps.

Rollback agent access by restoring the LiteLLM path to its original app directory
and removing only the Grounded Docs key grants through the existing key workflow.
Suspend the refresh schedule; do not delete the PVC. Suspending Flux alone does
not stop running pods. If application shutdown is needed, use an approved
GitOps change to its replica count. A previous image may not understand a newer
database schema: preserve a backup and recover into a separate claim instead of
assuming an image downgrade reverses migrations.

## Context7 source audit

A local Codex log audit covered 21 October 2026 23:04 UTC through 28 October
2026 23:04 UTC. It found 45 attempted Context7 calls in available session logs.
These are calls recorded in local exec orchestration, not account-wide usage or
confirmed successful retrievals. Queries and session contents are not copied here.

The added catalogue covers rumdl, Go PDF, go-sqlite3, Actual Budget, release-please,
reqwest, SeaORM, tempfile, GitHub Actions, Mealie, Kubernetes, pgx, Grape, Sequel,
Chart.js and Vite. The `mealie cli` request is mapped to Mealie documentation.
Deadvalues and Desloppify use their maintainer repositories. Moving sources use `current` labels.
