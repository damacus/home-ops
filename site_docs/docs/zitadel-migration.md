# Zitadel OIDC Migration Guide

## Overview

This guide documents the migration from Dex to Zitadel for OIDC authentication across Grafana, Paperless, and Mealie.

## Prerequisites

1. Zitadel instance running at `https://zitadel.ironstone.casa`
2. Google OAuth configured in Zitadel
3. Admin user with IAM_OWNER role in Zitadel
4. 1Password items created for each OIDC client

## Migration Steps

### 1. Create OIDC Clients in Zitadel

Run the setup script to create OIDC clients for all applications:

```bash
./scripts/zitadel-setup-oidc.fish
```

This script will:
- Create OIDC clients for Grafana, Paperless, and Mealie
- Store credentials in Kubernetes secrets in the `authentication` namespace
- Output client IDs and secrets for 1Password storage

### 2. Store Credentials in 1Password

Create the following 1Password items in the `home-ops` vault:

**zitadel-grafana-oidc:**
- `client-id`: [from script output]
- `client-secret`: [from script output]

**zitadel-paperless-oidc:**
- `client-id`: [from script output]
- `client-secret`: [from script output]

**zitadel-mealie-oidc:**
- `client-id`: [from script output] (public client, no secret)

### 3. Deploy Configuration Changes

The following changes have been made:

**Grafana** (`@/Users/damacus/repos/damacus/home-ops/kubernetes/apps/monitoring/grafana/app/helmrelease.yaml`):
- Added `auth.generic_oauth` configuration
- Configured Zitadel endpoints
- Added secret mount for OIDC credentials
- Enabled PKCE for security

**Paperless** (`@/Users/damacus/repos/damacus/home-ops/kubernetes/apps/home-automation/paperless/app/helmrelease.yaml`):
- Updated `PAPERLESS_SOCIALACCOUNT_PROVIDERS` to use Zitadel
- Created ExternalSecret to sync credentials from 1Password
- Provider ID changed from `dex` to `zitadel`

**Mealie** (`@/Users/damacus/repos/damacus/home-ops/kubernetes/apps/home/mealie/app/helmrelease.yaml`):
- Updated `OIDC_CONFIGURATION_URL` to Zitadel
- Changed provider name from `Dex` to `Zitadel`
- Updated scopes to match Zitadel claims
- Added ExternalSecret for client ID

### 4. Verify ExternalSecrets Sync

After deploying, verify that ExternalSecrets have synced:

```bash
# Check Grafana OIDC secret
kubectl get externalsecret -n authentication zitadel-grafana-oidc
kubectl get secret -n authentication zitadel-grafana-oidc

# Check Paperless OIDC secret
kubectl get externalsecret -n home-automation paperless-zitadel-oidc
kubectl get secret -n home-automation paperless-zitadel-oidc

# Check Mealie OIDC secret
kubectl get externalsecret -n home mealie-zitadel-oidc
kubectl get secret -n home mealie-zitadel-oidc
```

### 5. Run InSpec Tests

Test OIDC authentication for each application:

```bash
# Test Grafana OIDC
inspec exec kubernetes/apps/monitoring/grafana/tests

# Test Paperless OIDC
inspec exec kubernetes/apps/home-automation/paperless/tests

# Test Mealie OIDC
inspec exec kubernetes/apps/home/mealie/tests
```

### 6. Test Login Flows

**Grafana:**
1. Navigate to `https://grafana.ironstone.casa`
2. Click "Sign in with Zitadel"
3. Authenticate with Zitadel (local or Google)
4. Verify successful login and role assignment

**Paperless:**
1. Navigate to `https://paperless.ironstone.casa`
2. Click "Sign in with Zitadel"
3. Authenticate with Zitadel
4. Verify successful login

**Mealie:**
1. Navigate to `https://mealie.ironstone.casa`
2. Click "Sign in with Zitadel"
3. Authenticate with Zitadel
4. Verify successful login

## Zitadel OIDC Endpoints

All applications use these Zitadel endpoints:

```yaml
issuer: https://zitadel.ironstone.casa
authorization_endpoint: https://zitadel.ironstone.casa/oauth/v2/authorize
token_endpoint: https://zitadel.ironstone.casa/oauth/v2/token
userinfo_endpoint: https://zitadel.ironstone.casa/oidc/v1/userinfo
jwks_uri: https://zitadel.ironstone.casa/oauth/v2/keys
discovery: https://zitadel.ironstone.casa/.well-known/openid-configuration
```

## Rollback Plan

If issues occur, rollback by:

1. Reverting the HelmRelease changes
2. Re-enabling Dex configuration
3. Deleting Zitadel OIDC secrets

## Decommissioning Dex

Once all applications are successfully migrated and tested:

1. Remove Dex static clients from configuration
2. Scale down Dex deployment
3. Remove Dex HelmRelease
4. Clean up Dex secrets and ConfigMaps

## Troubleshooting

### Login Fails with "Invalid Redirect URI"

- Verify redirect URIs in Zitadel match exactly
- Check for trailing slashes
- Ensure HTTPS is used

### Secret Not Found

- Verify ExternalSecret has synced: `kubectl get externalsecret -n <namespace>`
- Check 1Password item exists and has correct fields
- Verify ClusterSecretStore is healthy

### OIDC Discovery Fails

- Verify Zitadel is accessible: `curl https://zitadel.ironstone.casa/.well-known/openid-configuration`
- Check network policies allow egress to Zitadel
- Verify DNS resolution

## References

- [Zitadel OIDC Documentation](https://zitadel.com/docs/guides/integrate/login/oidc)
- [Grafana OAuth Documentation](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)
- [Paperless OIDC Documentation](https://docs.paperless-ngx.com/configuration/#oidc)
