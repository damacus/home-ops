# Grounded Docs

Grounded Docs keeps a shared documentation index behind LiteLLM. Come here to
add a source, fix a failed refresh, or recover the index. The
[rollout history](../../../../docs/history/grounded-docs-rollout.md) keeps the
indexing problems and earlier activation procedure.

## Get to the service

- Management: <https://grounded-docs.ironstone.casa>, through OAuth2 Proxy and Zitadel.
- Agents: the existing LiteLLM MCP endpoint and key; see the [gateway guide](../litellm/README.md).
- Catalogue: [sources.json](app/sources.json), including versions and crawl settings.
- Configuration: [HelmRelease](app/helmrelease.yaml), [refresh schedule](app/refresh-cronjob.yaml), [Flux wiring](ks.yaml).
- Chart: [app-template documentation](https://bjw-s-labs.github.io/helm-charts/docs/app-template/).

Repository configuration checked on 14 November 2026: the app, backups and
weekly refresh are enabled. Refresh runs Sundays at 03:00 UTC. This source check
does not establish the latest crawl or restore result. Context7 remains the
fallback when coverage is missing.

## Check a failed refresh

Start with the scheduled Job and worker logs:

```console
kubectl --context ironstone -n dev get cronjob grounded-docs-refresh
kubectl --context ironstone -n dev get jobs --sort-by=.metadata.creationTimestamp
kubectl --context ironstone -n dev logs deploy/grounded-docs -c worker --tail=100
```

Inspect the failed Job's logs and its library/version in the management UI.
A timed-out Kubernetes Job can leave a worker job running: check before retrying.
Sync stops on failed versions, changed source URLs or active jobs rather than
replacing an index. A second refresh won't repair stored crawl options.

Correct the source's reviewed options in the catalogue and the existing version.
With no worker job active, rerun `scrape` for that exact library/version with
`--no-clean`. This updates options without clearing existing pages. The
[original Loco repair](../../../../docs/history/grounded-docs-rollout.md#catalogue-and-refresh)
has the full command and explains the broken relative README links.
Avoid `--replace`: it discards the existing index.

Check page counts and a representative search and page read before resuming
sync. Depth, scope and page limits can leave a completed crawl incomplete.

## Add or refresh a source

Add its canonical URL, version and crawl settings to `app/sources.json` through
a PR. Use fixed documentation versions where available; `current` follows
upstream and must be described that way.

Let the weekly schedule pick up the change, or create one manual Job after
confirming no refresh or worker job is already active:

```console
kubectl --context ironstone -n dev create job grounded-docs-refresh-manual --from=cronjob/grounded-docs-refresh
kubectl --context ironstone -n dev logs -f job/grounded-docs-refresh-manual
```

If that name exists, inspect its result before choosing another. Changing a
catalogue limit does not update an existing version's stored options; update
those through the management UI first. Compare useful pages and sitemap
coverage with stored results rather than relying on the page count alone.

## Access and storage constraints

One pod runs the worker, MCP frontend and management frontend. Only the worker
mounts SQLite on Longhorn. Keep one pod and `Recreate` updates; don't introduce
multiple SQLite writers or an RWX/NFS share.

Traefik reaches management, LiteLLM reaches read-only MCP, and labelled refresh
Jobs reach the worker. The worker's unauthenticated API stays internal.
Agent keys must not gain scrape/removal tools; application keys get no MCP
grants. Use existing LiteLLM key administration for permission changes.

Scraping permits public sites and excludes local files/private networks.
These application restrictions do not replace network policy. Check OOM events
and memory use if indexing restarts the frontends: early crawls outgrew their
original memory limits.

## Backup and recovery

Flux pruning is disabled on the PVC, but manually deleting it can still destroy
data. Dedicated Longhorn schedules live in `backup/`. A backup in the cluster's
RustFS is not an independent off-site copy.

Restore to a separate volume and run an isolated worker at the same image
version. Check SQLite integrity, library counts and known searches before
switching over. Preserve the original claim. Don't copy only live
`documents.db` without its journal/WAL or assume an image downgrade undoes a
schema migration.

Suspend the CronJob to stop scheduled refreshes. Suspending Flux alone doesn't
stop pods or jobs. Preserve the PVC while diagnosing a failure.
