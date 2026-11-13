# Memos

Memos uses app-template 5.3.0, SQLite on `memos-data`, and the existing KEDA
HTTP route at <https://notes.ironstone.casa>.

## Upgrade

This rollout assumes the existing instance has already run 0.31.0 or later.
The image is pinned to 26.11.0 rather than the moving `stable` tag.

1. Take a consistent backup of the SQLite database and attachments on
   `memos-data`. Confirm the restore procedure and retain the backup through
   acceptance. A rollback requires restoring that backup, not just reverting
   the image tag after database migrations.
2. Deploy the `26.11.0` image and declarative configuration in this
   directory. Confirm ExternalSecret `memos-oidc-config` is Ready before
   checking application startup. Users must sign in again after the upgrade.
3. Link the existing account to Zitadel and verify SSO before considering any
   change to password access or registration policy.

Production rollout and database restore are separate operational actions.

## Zitadel configuration

The `memos` web client was created using `zitadel-tui apps create`, with an
authorization-code flow, client-secret Basic authentication, and the exact
callback `https://notes.ironstone.casa/auth/callback`. Memos 26.11.0 detects the
provider's client authentication method automatically.

The 1Password item `zitadel-memos-oidc` in vault `home-ops` contains fields
`client_id` and `client_secret`. External Secrets renders those fields as JSON
in Secret `memos-oidc-config`, mounted read-only at `/etc/memos/config`.
No credentials belong in Git. Reloader restarts Memos after a Secret update.

Memos applies the provider at startup and marks it as managed by configuration.
Keep `identity-providers/zitadel` and the `sub` identifier mapping stable so
linked accounts continue to resolve. Existing registration and password
settings remain managed in Memos rather than being reset by this file.

Sign in with the existing Memos account, open account settings, and link
Zitadel before trying a standalone SSO login. An unlinked identity can create
a separate account when registration is allowed, or be rejected when it is
disabled. Keep a known administrator password for recovery.

After rollout, check allowed access by signing in through Zitadel and confirming
the existing notes appear. Check denied access with an invalid/expired callback
and an unlinked identity when registration is disabled. Local tests do not prove
production Cilium policies, KEDA wake-up behaviour or browser SSO.

Sources: [upgrade notes](https://usememos.com/changelog/26-10-0),
[declarative configuration](https://usememos.com/docs/configuration/declarative-configuration),
[26.11.0 release](https://github.com/usememos/memos/releases/tag/26.11.0).
