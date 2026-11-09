# Release Mirror

Public release metadata for private container images at
`https://releases.damacus.io`. Images and source repositories are not proxied.
The reusable application is maintained in
[damacus/release-mirror](https://github.com/damacus/release-mirror).

## Deployment

The deployment runs one non-root instance on port 9292, with SQLite stored on a Longhorn volume at `/data`. The PVC is protected from Flux pruning. The health check requires the public Host header and confirms only that the application responds.

The image is pinned to [v0.1.0](https://github.com/damacus/release-mirror/releases/tag/v0.1.0). Its published image index supports AMD64 and ARM64. Test the pinned image in the cluster before activation.

## Identity and secrets

Create a 1Password item named `release-mirror` in the vault used by
`onepassword-connect`, with these field labels:

| Field | Value |
| --- | --- |
| `session_secret` | At least 64 random bytes of secret material |
| `browser_client_id` | Zitadel confidential OIDC application client ID |
| `browser_client_secret` | That application's client secret |
| `bootstrap_subject` | Exact existing Zitadel user ID for the global administrator |

The ExternalSecret generates the environment credentials and read-only JSON
configuration. IDs are JSON-encoded when inserted into configuration. Do not
commit the generated Secret or print its values during verification.

Register authorization-code flow with S256 PKCE and exact callback
`https://releases.damacus.io/auth/oidc/callback` at
`https://zitadel.damacus.io`. Confirm the configured signing algorithm is
actually issued. New authenticated users remain read-only. Human API token
introspection is intentionally omitted; add its separate client only if needed.

The Forgejo issuer, key URL, `JWT` token type, `RS256` algorithm and one-hour
maximum lifetime in the configuration are proposed installation settings.
Verify discovery and an actual runner token before accepting them. No token
body belongs in logs or this repository. Enable workload OIDC in producer jobs.

After administrator login, create service `usage-ledger` and grant workload
issuer `https://forgejo.ironstone.casa/api/actions`, subject `534`, action
`publish`, scope `usage-ledger`. The audience is `https://releases.damacus.io`.
Any accepted build identity from that repository may publish; the catalogue
does not restrict branches. The grant does not permit deletion, service
creation or administration. Other producers need their own immutable repository
IDs and service grants. Ledger's Forgejo release/package credentials belong in
its Actions settings, not in the catalogue pod.

## Routing and checks

Cloudflare Tunnel and Traefik route `releases.damacus.io` to the service. Reads are anonymous; writes require authentication. The network policy permits ingress from Traefik. Middleware removes `Forwarded` and `X-Forwarded-Host` and limits request bodies to 1 MiB.

Before activation, configure the secrets and identity providers above. Confirm proxy logs exclude OAuth callback queries, credentials, cookies and request bodies. Traefik access logging is enabled; the route does not suppress it. Set up and test backups and a restore.

Test with synthetic metadata:

- Anonymous reads succeed; anonymous and invalid-token writes fail.
- The bootstrap administrator can create services and grants; a new user cannot administer them.
- Ledger repository 534 can publish to `usage-ledger`, but cannot delete releases or publish to another service. Another repository cannot publish to `usage-ledger`.
- Unrelated pods cannot reach the service directly; wrong Host headers and oversized requests are rejected.

Populate the six feeds needed by [PR #4738](https://github.com/damacus/home-ops/pull/4738), including deployed tags, before activating its Renovate rules.

## Backup and recovery

Set up scheduled backups and test a restore before activation. Use SQLite's online backup facility or
`VACUUM INTO` from the application image to create a new consistent file on
`/data`; copy only that completed backup to the approved backup destination.
Do not copy only the live main SQLite file while WAL writes are active. Protect
backups because they contain private grants and immutability settings.

For recovery, stop the application, preserve current files, restore a compatible
complete SQLite backup, remove stale WAL/SHM companions only while stopped,
retain ownership `10001:10001`, and start the same compatible application image.
Verify public metadata and permissions before reopening access. Restoring a
backup intentionally restores entries deleted after that backup. Public JSON
export excludes grants and is not a full operational backup.

See the application's [operating guide](https://github.com/damacus/release-mirror/blob/main/docs/operations.md)
for the SQLite backup example and contract details.
