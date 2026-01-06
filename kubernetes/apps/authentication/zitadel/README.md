# Zitadel Identity Provider

Zitadel is a modern identity and access management solution with built-in support for:

- Passkeys/WebAuthn authentication
- Multi-user management
- OIDC/OAuth2 provider
- External identity providers (Google, etc.)
- LDAP integration

## Prerequisites

### 1Password Items Required

Create the following items in 1Password before deploying:

#### `zitadel-db` (Login item)

- `username`: `zitadel`
- `password`: (generate secure password)

#### `zitadel-db-superuser` (Login item)

- `password`: (generate secure password for postgres superuser)

#### `zitadel` (Secure Note)

- `masterkey`: 32-character random string (e.g., `openssl rand -base64 24 | tr -d '\n' | head -c 32`)
- `db_password`: Same as `zitadel-db` password
- `db_superuser_password`: Same as `zitadel-db-superuser` password
- `admin_username`: Your admin username (e.g., `admin`)
- `admin_email`: Your admin email
- `admin_password`: Initial admin password

## Architecture

```text
┌─────────────────┐     ┌─────────────────┐
│   Zitadel App   │────▶│  PostgreSQL     │
│   (HelmRelease) │     │  (CNPG Cluster) │
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐
│  Gateway API    │
│  (HTTPRoute)    │
└─────────────────┘
```

## OIDC Applications

After Zitadel is deployed, configure OIDC applications for:

1. **Grafana** - `https://grafana.ironstone.casa/login/generic_oauth`
2. **Mealie** - `https://mealie.ironstone.casa/api/auth/oauth/callback`
3. **Paperless-ngx** - `https://paperless.ironstone.casa/accounts/oidc/zitadel/login/callback/`

## Google Identity Provider

The Google OAuth credentials from Dex are reused via the `zitadel-google-idp` ExternalSecret.
Configure the Google IDP in Zitadel console after deployment.

## Passkeys

Passkeys are enabled by default via the `PasswordlessType: 1` setting.
Users can enroll passkeys from their account settings.

## Access

- Console: `https://zitadel.ironstone.casa`
- API: `https://zitadel.ironstone.casa/oauth/v2/`
