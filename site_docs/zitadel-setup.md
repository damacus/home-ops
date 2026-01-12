# Zitadel Setup Guide

## Overview

Zitadel is now configured with:

- ✅ V2 login UI enabled and routed correctly
- ✅ Admin user with IAM_OWNER role
- ✅ Local authentication (username/password)
- ✅ Google OAuth identity provider
- ✅ OIDC clients for all applications

## Admin Access

Console URL: <https://zitadel.ironstone.casa/ui/console/>
Permissions: IAM_OWNER (full instance administration)

## Authentication Options

### 1. Local Authentication

Users can register and login with username/password (enabled by default).

### 2. Google OAuth

Google is configured as an identity provider:
- Users can login with their Google account
- Users can link Google to existing local accounts
- Auto-creation is disabled (requires manual approval)
- Auto-update is enabled (profile updates from Google)

## OIDC Clients

OIDC clients can be created using the `zitadel-create-oidc-clients.fish` script or manually through the console UI. Client credentials are saved to `/tmp/zitadel-clients.txt` when using the script - store them securely in 1Password or your secrets management system.

## OIDC Endpoints

When configuring applications, use these Zitadel endpoints:

```yaml
issuer: https://zitadel.ironstone.casa
authorization_endpoint: https://zitadel.ironstone.casa/oauth/v2/authorize
token_endpoint: https://zitadel.ironstone.casa/oauth/v2/token
userinfo_endpoint: https://zitadel.ironstone.casa/oidc/v1/userinfo
jwks_uri: https://zitadel.ironstone.casa/oauth/v2/keys
```

## Management Scripts

All scripts are located in `scripts/` and use fish shell syntax:

- `zitadel-create-admin.fish` - Create admin user for console access
- `zitadel-grant-admin.fish` - Grant IAM_OWNER role to admin user
- `zitadel-configure-auth.fish` - Configure Google OAuth identity provider
- `zitadel-create-oidc-clients.fish` - Create OIDC applications

## Deleting OIDC Clients

To delete OIDC clients (for testing/recreation), use the Zitadel console:

1. Navigate to Projects → Default Project
2. Click on Applications
3. Select the application to delete
4. Click Delete

Or use the API:

```fish
set PAT (kubectl get secret -n authentication zitadel-admin-sa-pat -o jsonpath='{.data.pat}' | base64 -d)
set PROJECT_ID "355223427969320100"
set APP_ID "your-app-id"

curl -X DELETE "https://zitadel.ironstone.casa/management/v1/projects/$PROJECT_ID/apps/$APP_ID" \
  -H "Authorization: Bearer $PAT"
```

## Next Steps

1. Create OIDC clients for your applications (via script or console)
2. Update application configurations with client IDs and secrets
3. Test authentication flows
4. Migrate from Dex once all applications are working

## Troubleshooting

### Login UI Returns 404

- Check HTTPRoute has routing rule for `/ui/v2/login`
- Verify `zitadel-login` service is running
- Check `login.enabled: true` in HelmRelease

### User Has No Admin Access

- Run `./scripts/zitadel-grant-admin.fish`
- Log out and log back in to refresh permissions

### OIDC Client Not Working

- Verify redirect URIs match exactly
- Check client secret is correct
- Ensure OIDC endpoints are configured correctly
- Check Zitadel logs: `kubectl logs -n authentication -l app.kubernetes.io/name=zitadel`

## References

- [Zitadel Documentation](https://zitadel.com/docs)
- [Zitadel Management API](https://zitadel.com/docs/apis/resources/mgmt)
- [OIDC Configuration Guide](https://zitadel.com/docs/guides/integrate/login/oidc)
