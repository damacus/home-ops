# Release Mirror

Public release metadata for private container images at
`https://releases.damacus.io`. Images and source repositories are not proxied.
The reusable application is maintained in
[damacus/release-mirror](https://github.com/damacus/release-mirror).

## Deployment state

This deployment is staged, not activated. Its Flux Kustomization has
`suspend: true`. The image tag `pending-publication` is an explicit unavailable
placeholder, not a published version. Do not resume reconciliation or apply the
application directory manually. No credentials or identity-provider settings
were provisioned as part of this change.

Before activation, replace the placeholder with a reviewed published tag and
OCI image-index digest. Verify the index contains `linux/arm64` and `linux/amd64`
and run the application contract against that exact image. The public GHCR
image should require no pull credential. Image publication is being prepared in
the application repository separately.

One non-root Puma process listens on port 9292. SQLite and its WAL live on one
Longhorn RWO PVC at `/data`; `/tmp` is ephemeral. Recreate upgrades prevent two
instances from sharing the database. The PVC is protected from Flux pruning.
Do not increase replicas or mount the volume into another application writer.
The health probes send the required public Host header. `/health` only proves
the application responds, not successful database writes or identity access.

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

## Public routing and activation gates

The HTTPRoute uses the existing wildcard Cloudflare Tunnel, Traefik HTTPS
listener and `damacus.io` certificate. There is no shared forward-auth gate:
anonymous catalogue reads must remain available, while the application checks
credentials on writes. NetworkPolicy permits application ingress only from
Traefik pods in `network`. Egress is not restricted by this application policy;
the pod needs DNS, Forgejo signing keys and Zitadel HTTPS access.

Route middleware removes caller-supplied `Forwarded` and `X-Forwarded-Host` and
limits request bodies to 1 MiB. Preserve `Host: releases.damacus.io` through the
complete proxy chain. This is declarative configuration, not proof of live
header handling or routing.

**Proxy logging is an unresolved activation gate.** Traefik currently enables
access logging. Before exposing login, ensure the full Cloudflare/Traefik path
does not log OAuth callback query strings, authorization headers, cookies or
request bodies. The route middleware does not suppress access logs. Review a
supported route-specific logging configuration or a separately scoped shared
proxy change; this deployment does not change logging for existing services.

Before any approved activation, resolve image publication, 1Password fields,
Zitadel registration, actual Forgejo claims and proxy logging. Then validate:

| Case | Expected result |
| --- | --- |
| Anonymous directory, service JSON and Renovate feed | Read succeeds without cookies or credentials |
| Anonymous or invalid-token write | Rejected |
| New Zitadel user | Can read; cannot administer or delete |
| Explicit bootstrap administrator | Can create aliases and grant permissions |
| Ledger repository 534 publishing to `usage-ledger` | Succeeds with valid issuer/audience/lifetime |
| Different repository or Ledger writing another service | Rejected |
| Publisher deleting releases or managing grants | Rejected |
| Direct access from an unrelated pod | Denied by NetworkPolicy |
| Wrong Host or oversized request | Rejected |

Use synthetic metadata first. Inspect sanitized diagnostics without exporting
tokens or callback URLs. Populate all six aliases required by home-ops PR
#4738, including currently deployed tags, before activating its Renovate rules.
Changing suspension, merging, Flux reconciliation and production publication
remain separate owner-approved actions.

## Backup and recovery

Scheduled backup automation and a restore rehearsal remain activation gates.
The PVC alone is not a backup. Use SQLite's online backup facility or
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
