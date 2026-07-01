# Med Tracker Canary

This lane is for risky Med Tracker application and security upgrades. It uses
the same application image stream as production, but every mutable runtime
resource is canary-specific:

- `med-tracker-canary-secret`
- `med-tracker-canary-storage`
- `med-tracker-canary` HelmRelease, Service, HTTPRoutes, and NetworkPolicy
- `med-tracker-canary` CNPG cluster
- `med-tracker-canary-db` and `med-tracker-canary-db-superuser`
- `med-tracker-canary-rustfs-store`

The canary CNPG cluster bootstraps from the production `med-tracker` Barman
backup source and then uses its own secret for the application database user.
Canary WAL archiving uses the `cnpg-med-tracker-canary` RustFS bucket.

## Refresh And Promotion

1. Reconcile `med-tracker-canary-db` to restore the latest production backup
   into the isolated canary cluster.
2. Deploy the candidate image tag to `med-tracker-canary`.
3. Let the migration initContainer run against
   `med-tracker-canary-rw.home.svc.cluster.local`.
4. Smoke test `/up`, `/login`, the authenticated dashboard, and an admin path.
5. Run baseline performance and security checks.
6. Promote the exact image tag to production only after canary passes.

The production hostname, production PVC, production Kubernetes secret, and
`med-tracker-rw.home.svc.cluster.local` must not be modified during canary
refreshes or migration tests.
