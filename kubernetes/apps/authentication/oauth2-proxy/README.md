# OAuth2 Proxy Forward Auth

This deploys a shared OAuth2 Proxy instance for Traefik `ForwardAuth` using Zitadel as the OIDC provider.

Before reconciling, create a 1Password item named `zitadel-oauth2-proxy-oidc` with:

- `client_id`
- `client_secret`
- `cookie_secret`

The Zitadel app redirect URI should be:

```text
https://auth.ironstone.casa/oauth2/callback
```

To protect an app later, add a Traefik `ExtensionRef` filter to that app's `HTTPRoute` rule. The middleware must exist in the same namespace as the `HTTPRoute`; this scaffold creates `oauth2-proxy-forward-auth` and `oauth2-proxy-auth-only` in the likely app namespaces.

```yaml
filters:
  - type: ExtensionRef
    extensionRef:
      group: traefik.io
      kind: Middleware
      name: oauth2-proxy-forward-auth
```

Use `oauth2-proxy-forward-auth` for browser apps that should redirect to Zitadel. Use `oauth2-proxy-auth-only` for API paths that should return `401` instead of redirecting.
