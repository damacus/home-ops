# Isolated Rails 0.5 acceptance source

This is a disposable synthetic source for clinical transfer acceptance, not a
production recovery environment. It has its own namespace, CNPG cluster,
credentials and disk. Do not enter real patient data. It has no worker, scheduled
reset, backup or outbound notification route. The suspended CronJob is a template
for **one initial seed only**; creating another Job destroys its database contents
and disk files. Never point it at any existing environment. The web Deployment is
initially scaled to zero and the Flux Kustomization is suspended.

## Prerequisites and activation

After independent review, the controller provisions separate 1Password items:
`medtracker-05-canary-db` with `password` for initialisation,
`medtracker-05-canary-web-db` with a different `password` for web access, and
`medtracker-05-canary-runtime` with `secret_key_base` (a new Rails secret, for
example from `bin/rails secret`).
Do not use production keys. Ensure the cluster's PostgreSQL 18 image catalogue,
OpenEBS, External Secrets store, gateway certificate and DNS support this namespace
and hostname. Confirm the pinned image is pullable on the chosen node. No OIDC,
SMTP, push or other outbound service is configured.

Publish reviewed manifests, resume only `medtracker-05-canary` through GitOps,
and wait for all ExternalSecrets, the CNPG primary and all three auxiliary CNPG
Databases to be ready. The PVC may remain Pending until its first consumer.
Before any seed, inspect resource names and
connection targets: the only database host must be
`medtracker-05-rw.medtracker-05-canary.svc.cluster.local` and storage must be
the new `medtracker-05-storage` PVC. Confirm no other pods mount it and the web
Deployment has zero replicas. Create the read-only inspection Job as the first
consumer; check the Job's pod references that exact PVC and read-only mount,
the claim binds to a newly provisioned volume, and its log says `storage-empty`.
Do not proceed on any failed check. Delete the completed inspection Job and wait
for its pod to disappear before starting initialisation:

```fish
kubectl -n medtracker-05-canary create job --from=cronjob/medtracker-05-inspect-storage medtracker-05-inspect-once
kubectl -n medtracker-05-canary wait --for=condition=complete job/medtracker-05-inspect-once --timeout=5m
kubectl -n medtracker-05-canary get pvc medtracker-05-storage -o wide
kubectl -n medtracker-05-canary get pods -l job-name=medtracker-05-inspect-once -o yaml
kubectl -n medtracker-05-canary logs job/medtracker-05-inspect-once
kubectl -n medtracker-05-canary delete job medtracker-05-inspect-once --wait=true
kubectl -n medtracker-05-canary wait --for=delete pod -l job-name=medtracker-05-inspect-once --timeout=2m
```

If the last command says no matching resources exist, the pod has already gone;
otherwise require successful deletion. Confirm no remaining pod mounts the PVC.
The initialisation Job runs `db:prepare`, grants the application role access to
the three auxiliary databases' existing tables and sequences, and then runs the
Rails guarded reset. Primary-database grants come from Rails migrations. The reset checks
the application hostname, every configured database host, database role, disk
service and actual mounted root; it truncates the databases and clears the disk.
Those checks do not substitute for independently verifying the target.

With these preconditions proved, run once:

```fish
kubectl -n medtracker-05-canary create job --from=cronjob/medtracker-05-initialise medtracker-05-initialise-once
kubectl -n medtracker-05-canary wait --for=condition=complete job/medtracker-05-initialise-once --timeout=15m
kubectl -n medtracker-05-canary logs job/medtracker-05-initialise-once
```

Require `canary.demo_reset` outcome `succeeded` and baseline `weekly-demo-v1`;
record the actual seed time and Job image digest. A failure or interruption is
not permission to rerun: investigate state and agree recovery first. Do not scale
the web up around a failed seed. After successful initialisation, change the
Deployment's `replicas` to `1` through reviewed GitOps and wait for `/up`. Do not
enable the CronJob. Confirm the gateway is the only intended ingress and test
both allowed and denied paths: gateway to web and web to the dedicated DB must
work; unrelated pods to web, web to the Kubernetes API, production databases,
SMTP, push and external Internet must fail. Static manifests cannot prove these
live network outcomes. Verify HTTPS and sign in as `demo.owner@example.com` or
`demo.carer@example.com` with fixture password `password`. This public fixture
password makes the environment suitable only for synthetic disposable data.

The web uses `medtracker_05_web`, which can assume `med_tracker_app` only; the
initialisation secret alone contains the `medtracker_05` owner-capable login.
Before acceptance, use the web pod's Rails connection to check the effective
identities and privileges, then prove `SET ROLE med_tracker_owner` and an
`ALTER TABLE people DISABLE ROW LEVEL SECURITY` attempt are denied with SQLSTATE
`42501`. Run each attempted change in a transaction and roll it back even if it
unexpectedly succeeds. Exercise sign-in, normal web access and the hosted export
below using the web pod; do not treat static role definitions as proof.

```fish
kubectl -n medtracker-05-canary exec deploy/medtracker-05 -- bin/rails runner 'c = ActiveRecord::Base.connection; puts c.select_one("SELECT session_user, current_user, pg_has_role(session_user, '\''med_tracker_owner'\'', '\''MEMBER'\'') AS owner_member, has_schema_privilege(current_user, '\''public'\'', '\''CREATE'\'') AS schema_create, has_table_privilege(current_user, '\''people'\'', '\''TRUNCATE'\'') AS people_truncate").inspect'
kubectl -n medtracker-05-canary exec deploy/medtracker-05 -- bin/rails runner 'c = ActiveRecord::Base.connection; ["SET LOCAL ROLE med_tracker_owner", "ALTER TABLE people DISABLE ROW LEVEL SECURITY"].each { |sql| begin; c.transaction(requires_new: true) { c.execute(sql); raise "UNEXPECTED SUCCESS: #{sql}" }; rescue ActiveRecord::StatementInvalid => e; raise unless e.cause.respond_to?(:result) && e.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE) == "42501"; puts "denied: #{sql}"; end }'
```

Require `session_user` `medtracker_05_web`, `current_user` `med_tracker_app`,
and all three privilege booleans false. Require both denial lines. An unexpected
success aborts and rolls back the transaction; any other error is a failed check.

## Baseline and evidence

The pinned `v0.5.35` fixture contains Alex Demo and Casey Demo (adults), Rowan
Demo (child), one household, two medicines, one daily schedule and one
as-needed assignment, two takes, one storage location and three person-location
memberships. Both takes record the medicine and location taken from. Casey has an
active `professional_carer` relationship to Rowan; the fixture separately grants
Casey `record` access, while Alex has `manage` access. Neither relationship nor
source permissions grant authority in the destination. The source also has five
person access grants. The exporter serializes the three location memberships as
person `location_portable_ids`, but does not serialize carer relationships or
access grants as records. It also omits Casey's `professional_title` and the
medicines' `expiry_date` and `supply_at_last_restock` fields. Record these source
omissions explicitly; the obsolete person-location links may be acknowledged as
unsupported in the destination. The baseline verifier
expects no attachments or delivery credentials at seed time; inspect the actual
archive for attachments and later changes.

Rowan's birth date is ten years before fixture evaluation. The daily schedule
starts on the seed date and ends one year later; takes use 08:00 and 12:00 on
the seed date in the configured time zone. Record the actual values from the
export and seed time; never substitute guessed calendar dates.

## Complete hosted household export

Run only after the synthetic seed and identity have been verified. The fixture
IDs below come from Rails' fixture identifier function, not guessed IDs. The
owner's membership authorises the hosted exporter. Keep the resulting archive
private even though this baseline is synthetic. Do not print its contents into
shared logs. The export is synchronous and creates an audited export and an
attachment in the source; this step does not reset it.

```fish
set ns medtracker-05-canary
set pod (kubectl -n $ns get pod -l app=medtracker-05 -o jsonpath='{.items[0].metadata.name}')
set fixture_ids (kubectl -n $ns exec $pod -- bin/rails runner 'puts [:demo_household, :demo_owner, :demo_owner].map { |name| ActiveRecord::FixtureSet.identify(name) }.join(" ")' | string split ' ')
set household_id $fixture_ids[1]
set actor_id $fixture_ids[2]
set membership_id $fixture_ids[3]
kubectl -n $ns exec $pod -- env HOUSEHOLD_ID=$household_id ACTOR_ACCOUNT_ID=$actor_id MEMBERSHIP_ID=$membership_id bin/rails household_lifecycle:export
```

Read `export_id` from the `household.export.ready` JSON and set it below. Choose
a fresh filename: the transfer refuses to overwrite an existing file. Verify the
reported SHA-256 against the downloaded bytes before handing them to the importer.

```fish
set export_id REPLACE_WITH_EXPORT_ID
umask 077
if kubectl -n $ns exec $pod -- env HOUSEHOLD_ID=$household_id ACTOR_ACCOUNT_ID=$actor_id EXPORT_ID=$export_id DESTINATION=/app/storage/exports/household-$export_id.zip bin/rails household_lifecycle:download
    and kubectl -n $ns exec $pod -- cat /app/storage/exports/household-$export_id.zip >? ./medtracker-05-household-$export_id.zip
    shasum -a 256 ./medtracker-05-household-$export_id.zip
    unzip -l ./medtracker-05-household-$export_id.zip
else
    echo 'Download failed; do not use this file' >&2
end
```

Check the archive contains `manifest.json`, `portable.json` and any listed
attachment entries, then compare record counts, relationships, dates and fields
with the seed and importer results. Preserve the archive and checksum for the
acceptance run; do not delete or reset the source while it is needed.
