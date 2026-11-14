---
title: "Zitadel OIDC Migration Guide"
layout: documentation
doc_type: history
description: Earlier Dex-to-Zitadel migration and integration lessons.
---

# Zitadel OIDC Migration Guide

## Historical migration context

This page records the earlier move from Dex to Zitadel for Grafana, Paperless
and Mealie. It is not a procedure to rerun that migration. The old Fish setup
scripts and `kubernetes:test-app` task are not available, and the repository no
longer has a Dex application deployment.

For new clients and current account-admission policy, use the
[Zitadel setup guide](../zitadel-setup.md). Current manifests and application
operating guides take precedence over the historical migration descriptions.

## Current integration sources

| Application | Current configuration | Secret wiring |
| --- | --- | --- |
| Grafana | [Helm release](../../kubernetes/apps/monitoring/grafana/app/helmrelease.yaml) | ExternalSecret `zitadel-grafana-oidc` in `monitoring`, reading the same-named 1Password item |
| Paperless | [Helm release](../../kubernetes/apps/home-automation/paperless/app/helmrelease.yaml) | ExternalSecret `paperless` in `home-automation` creates `paperless-secret` and includes the `zitadel-paperless-oidc` item |
| Mealie | [Helm release](../../kubernetes/apps/home/mealie/app/helmrelease.yaml) | ExternalSecret `mealie-zitadel-oidc` in `home`, reading the `zitadel-mealie-oidc` item |

The current templates use 1Password properties `client_id` and
`client_secret`. Mealie's current configuration consumes both; the old
description of a public client without a secret does not match these manifests.

Existing client IDs and secrets should be preserved during maintenance. Use the
console or the supported API for the installed Zitadel version when a client
needs updating; no repository script creates them automatically.

## Validate a configuration change

Run the maintained render/schema command before proposing a manifest change:

```console
task kubernetes:yayamlls
```

This checks configuration structure. It does not test an OIDC login or prove
allowed and denied access. After an approved rollout, inspect ExternalSecret
status without decoding credentials:

```console
kubectl -n monitoring get externalsecret zitadel-grafana-oidc
kubectl -n home-automation get externalsecret paperless
kubectl -n home get externalsecret mealie-zitadel-oidc
```

Verify the relevant application through its currently configured public URL:

1. Start with a signed-out browser and follow the Zitadel sign-in flow.
2. Sign in with an existing authorised account and verify its application role.
3. Verify that an account outside the allowed group or assignment is denied
   according to that application's configured policy.
4. Confirm self-registration and unknown Google account creation remain denied.
5. Record which live cases passed and which remain unverified, without saving
   credentials, tokens or clinical/user data.

For changes under development, use the explicit Docker Desktop context and
synthetic accounts/data. Static checks and an isolated environment do not prove
production gateway or network-policy behaviour.

## Discovery, claims and recovery

Applications should use the issuer's discovery document:

```text
https://zitadel.damacus.io/.well-known/openid-configuration
```

Compare callback URLs, client authentication methods, scopes and expected
claims against each application's current configuration. Use the maintained
[Zitadel Actions guide](../../kubernetes/apps/authentication/zitadel/actions/README.md)
for group and RustFS claim behaviour.

If a configuration change breaks access, revert the specific reviewed change
and restore its known-working client configuration. Do not re-enable Dex or
delete existing OIDC credentials as a generic rollback step.

## References

- [Zitadel OIDC integration](https://zitadel.com/docs/guides/integrate/login/oidc)
- [Zitadel APIs](https://zitadel.com/docs/apis/introduction)
- [Grafana generic OAuth](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)
- [Paperless configuration](https://docs.paperless-ngx.com/configuration/)
