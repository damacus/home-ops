# Stage Redis migration prerequisites

This change adds only Secret delivery, a protected persistent volume and a
narrow network-policy allowance for `redis-migration` pods in `database`.
It does not change the Redis HelmRelease or application environment variables.
Create the `redis-auth` item in the home-ops vault before merging.

Fields: `admin_password`, `paperless_password`, `n8n_password`, `penpot_password`.
Use distinct URL-safe random credentials, each with at least 32 bytes of entropy.
Check ExternalSecret readiness without printing their values.

The export Job in `migration/export-job.yaml` is intentionally not included in
Kustomize. Quiesce producers and drain active work before adding it to the Redis
Kustomization through Git. It exports and validates a consistent RDB onto the
new PVC and refuses to overwrite an existing snapshot or AOF directory. Retain
an independent rollback copy and validate restoration before replacing Redis.
Failed exports use a unique temporary file and clean only that file. A validated
snapshot is atomically published without replacing an existing final snapshot.
Remove the helper Job and its ingress allowance after successful cutover.

The final configuration is in PR #4431. Follow its REDIS-ROLLOUT.md procedure;
do not merge it merely because its automated checks pass.
