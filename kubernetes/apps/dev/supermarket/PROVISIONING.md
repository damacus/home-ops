# Provisioning verification — 2026-09-08

Provisioning completed in the `ironstone` cluster. Application rollout and Git
publication remain outstanding.

- Created and verified the six dedicated 1Password items listed in README.md,
  in the `home-ops` vault. No existing credentials were replaced.
- Corrected the two database items to Database and the three RustFS items to
  API Credential using value-verified replacements; archived the superseded
  Secure Notes. The signing pair remains a Secure Note. Forced all seven
  ExternalSecrets to refresh and verified their Kubernetes Secret data remained
  identical after the category correction.
- All seven ExternalSecret resources reached Ready: six in `dev`, one in
  `storage`. The database owner and runtime credentials remain separate.
- Created the `cinc-registry-oci`, `cinc-registry-artifacts`, and
  `cnpg-cinc-registry` RustFS buckets, each with its own IAM account and policy.
- The one-off `cinc-registry-provision-20260908` Job completed successfully.
  Each account wrote, read and deleted its own test object. Listing either of
  the other two buckets returned an access-denied response.
- No CNPG cluster, Zot deployment or Cinc application workload was deployed.
  No cookbook import ran. No Git changes were published.

The temporary provisioning Job and ConfigMap are removed after verification.
ExternalSecrets remain active so credential changes in 1Password can sync.
The GitOps bucket Job may safely ensure these same users and buckets when the
deployment is subsequently published.
