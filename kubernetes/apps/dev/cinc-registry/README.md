# Local Cinc Registry

Runs in `dev`: one API, one worker, one artifact gateway, a separate Zot
app-template release, and a dedicated two-instance PostgreSQL 18 CNPG cluster.
All Cinc workloads use the same digest-pinned `fa4e9796` image. Zot uses 2.1.21
for ARM64, pinned by digest. PostgreSQL 18 is also digest-pinned.

The pinned Cinc image is anonymously pullable; no GitLab pull credential is needed.

The internal routes follow the existing Traefik Gateway configuration:

- API and browse UI: `https://cinc-registry.ironstone.casa`
- Download gateway: `https://cinc-artifacts.ironstone.casa`
- Zot: `zot.dev.svc.cluster.local:5000`, ClusterIP only, bearer authenticated.

Zot stores OCI data in RustFS. Downloads use a separate S3 copy through the
credential-free artifact gateway. The database stores universe snapshots;
the worker regenerates them after ingest. No additional snapshot bucket is needed.
Human login and CI publishing are not configured for this read/import trial.

## Secrets required before rollout

Create these items in the vault exposed by the `onepassword-connect`
ClusterSecretStore. Never commit their values. Use different random passwords
for each database account and different access keys for each S3 identity.

| Item | Category | Fields | Use |
| --- | --- | --- | --- |
| `cinc-registry-db-owner` | Database | `password` | CNPG bootstrap and migrations only |
| `cinc-registry-db-runtime` | Database | `password` | `cinc_sm_runtime` account |
| `rustfs-cinc-registry-oci` | API Credential | `username`, `password` | Bucket `cinc-registry-oci` |
| `rustfs-cinc-registry-artifacts` | API Credential | `username`, `password` | Bucket `cinc-registry-artifacts` |
| `rustfs-cnpg-cinc-registry` | API Credential | `username`, `password` | Bucket `cnpg-cinc-registry` |
| `cinc-registry-oci-signing` | Secure Note | `signing_key`, `certificate` | Matching private key and public certificate |

API Credential items contain their native `credential` field plus a concealed
`password` compatibility field with the same secret, as required by the existing
ExternalSecret property references. Keep both fields consistent when rotating keys.

Generate the signing pair with the pinned Cinc binary:

```sh
cinc-supermarket gen-oci-key --out oci-signing-key.pem --cert-out oci-token.crt
```

Store the file contents in the respective fields. Only Cinc receives the private
key; Zot receives the certificate. Keep the private key out of logs and Git.
The gateway receives no database, OCI or S3 credentials.

The separate `cinc-registry-buckets` Flux Kustomization in `storage` invokes the
existing RustFS provisioner with the new `cinc-registry` scope. It creates only
these three buckets and their individual IAM users/policies. It does not run
the provisioner's `all` scope or change credentials for existing applications.
The existing bucket policy grants object read/write/delete plus bucket listing
and multipart operations, restricted to that identity's single bucket.

## Rollout and acceptance

Flux orders the work as follows:

1. Provision buckets and IAM users, then reconcile CNPG and Zot.
2. Reconcile Cinc configuration and ExternalSecrets.
3. Run the versioned `cinc-registry-bootstrap` Job: migrate using the owner account in
   an init container, then generate an initial universe with the runtime account.
   Artifact delivery is disabled only for the migration process because it has
   no artifact credentials and does not access artifact storage.
4. Install the Cinc app-template release and wait for API/worker/gateway probes.
5. Run `cinc-registry-import-trial-fa4e9796` once. It imports the image's embedded
   five-cookbook set: nginx, yum, apt, logrotate and cron. It has a two-hour
   deadline, a 1 GiB memory limit and no automatic retries or scheduled sync.

Jobs have no TTL, so successful reconciliation does not repeatedly recreate
them. Do not delete the completed import Job unless intentionally repeating the
import. Flux will recreate a deleted managed Job. After inspecting a failed
import's logs and correcting the cause, deleting that Job explicitly retries it.
The ingester checks existing versions; verify the second run imports no duplicates.

Check Job completion, all three Deployment readiness conditions, CNPG readiness,
and the first successful scheduled backup. Check both HTTPRoutes are accepted.
Then confirm `/healthz`, `/readyz`, `/universe`, `/api/v2/packages` and the legacy
nginx version/download endpoints. Follow a download through the artifact hostname
and compare its SHA-256 with the API's advertised artifact digest. Confirm an
unsigned direct request to Zot `/v2/` is rejected and no direct S3 route exists.
Verify each RustFS identity cannot list another application's bucket.

No publish, data deletion or legacy ownership transfer is part of this trial.
The five-cookbook starter list is not the full Sous-Chefs dependency closure.

## Updates and recovery

Refresh the Cinc tag and digest in the HelmRelease and bootstrap Job together. Rename
the bootstrap Job with the new short SHA so migrations run before the upgraded
application. Keep the completed trial Job's name stable unless a new import is
intentional. The bootstrap Kustomization can replace immutable Jobs; the import
Kustomization deliberately cannot silently replace a completed Job on image edits.

CNPG uses 10 GiB `openebs-hostpath` storage per instance, continuous WAL archiving,
and a daily backup with 30-day retention. Zot uses a 1 GiB local PVC for its working
state; OCI payloads reside in RustFS. PostgreSQL backups do not back up the OCI or
artifact buckets. Retain these buckets and the signing pair during recovery.
Do not remove the Flux Kustomizations as a rollback: pruning would remove owned
resources. Suspend the new Kustomizations first and inspect database migrations
before attempting an application image rollback.

## Local checks

```sh
kubectl kustomize kubernetes/apps/dev
kubectl kustomize kubernetes/apps/storage
```

Render both releases with app-template 5.1.0 and validate the output with
`kubeconform -strict -summary`. Server-side dry-run the rendered workloads and each
app Kustomization against the cluster to validate its installed CRD schemas.
These checks do not prove successful import, backup or artifact delivery; those
require provisioned secrets and the running deployment.
