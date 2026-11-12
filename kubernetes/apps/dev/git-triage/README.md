# Git Triage

Git Triage runs at `https://git-triage.ironstone.casa` behind the internal Traefik
Gateway. Basic Auth is explicitly disabled for this deployment. External DNS
manages the hostname.

The image is built and published by the Git Triage GitHub CI workflow after its
application and browser jobs pass on main. Use the digest recorded by that job;
never publish or deploy a workstation-built image. The GHCR package is public.

Flux deploys three stages: the dedicated CNPG database on Longhorn, the migration
Job, then the application and route. CNPG WAL archiving and daily backups use an
isolated `git-triage/` prefix in the existing CNPG RustFS bucket. The database
Kustomization does not prune database resources.

The pre-existing `dev` Secrets `git-triage-runtime-db`, `git-triage-runtime`, and
`git-triage-migration` contain the database login, application signing/encryption
keys, retained Basic Auth credentials and migration login. The application does
not read the retained Basic Auth credentials. Secret values are not committed.
CNPG also owns the generated `git-triage-app` and `git-triage-superuser` Secrets.
Migration credentials are never mounted into the application container.

GitHub OAuth uses the `github_client_id` and `github_client_secret` keys in the
runtime Secret, read through private files. The OAuth app callback is
`https://git-triage.ironstone.casa/auth/github/callback`. Keep token expiration
enabled; the application rotates the encrypted token pair before expiry. An
interrupted or failed refresh requires reconnecting through Settings rather than
replaying the refresh token. Existing PAT connections remain supported.

Keep `+Q 65536` in `ERL_FLAGS`: the container runtime's large file-descriptor
limit can otherwise make Erlang reserve more than 1.5 GB for the port table.

For an update, pin the CI-produced image digest in both `app/resources.yaml` and
`migration/job.yaml`, and use a new migration Job name for that source revision.
Confirm all three Flux Kustomizations are Ready, `/health/ready` returns 200 over
HTTPS, product pages open without a Basic Auth prompt, and anonymous LiveView
connections and interactions work. Do not seed demo fixtures in production.
