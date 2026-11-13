---
title: "Zitadel Setup Guide"
layout: documentation
---

# Zitadel Setup Guide

The repository configures Zitadel at
[the administration console](https://zitadel.damacus.io/ui/console/).
The Helm release enables the separate Login UI and the HTTPRoute sends
`/ui/v2/login` to `zitadel-login`. These are declared settings, not a claim that
a live login has just been verified.

Use the [application operating guide](../kubernetes/apps/authentication/zitadel/README.md)
for deployment prerequisites, credential sources and certificate wiring.

## Administrators and account admission

Sign in with an existing instance administrator. An existing owner can grant
the required administrator role through the console's administrator management.
Use an organisation or project role for application access; instance-owner
privileges are for instance administration.

There are no repository scripts for creating administrators, granting roles or
creating OIDC clients. Use the supported console workflow or the
[Zitadel APIs](https://zitadel.com/docs/apis/introduction) for the installed
server version. Keep API credentials in the secret store; do not write PATs,
client secrets or service-account keys into temporary credential reports.

The Git-managed
[access policy](../kubernetes/apps/authentication/zitadel/app/access-policy.yaml)
allows existing accounts to use local passwords and passkeys, and enables the
explicitly configured Google provider. It disables self-registration and
identity-provider account creation. Google may link to an existing account by
email, but may not create a new one.

The `zitadel-access-policy` CronJob reconciles these settings hourly. Change
the complete policy in Git rather than relying on console edits that the
reconciler will overwrite. Do not use the legacy hardening script to replace
this policy.

## Configure an OIDC application

1. In the console, select the intended organisation and application project.
   Create a project if necessary. Do not repurpose Zitadel's built-in default
   project, which protects its own console and APIs.
2. Open the project's applications and create or update an OIDC application.
   Select the application type and authentication method supported by the
   integrating application.
3. Register its exact HTTPS callback and logout URLs from that application's
   current configuration. Do not reuse callback URLs from historical examples.
4. Store the client ID and, for confidential clients, client secret in the
   existing 1Password item referenced by the application's ExternalSecret.
5. Let External Secrets and Flux reconcile the configuration, then verify an
   allowed login and the intended denied-access case.

Follow [Zitadel's project documentation](https://zitadel.com/docs/guides/manage/console/projects-overview)
and [OIDC integration guide](https://zitadel.com/docs/guides/integrate/login/oidc)
for the console/API procedures. For an existing client, update it in place
rather than deleting and recreating it unnecessarily.

Where an application relies on custom groups or RustFS policy claims, follow
the maintained [Actions guide](../kubernetes/apps/authentication/zitadel/actions/README.md)
as well. Successful authentication alone does not prove the correct role was
assigned.

## Discovery and verification

Use the issuer's discovery document instead of copying endpoint lists:

```text
https://zitadel.damacus.io/.well-known/openid-configuration
```

Check declared Kubernetes resources without printing secret data:

```console
kubectl -n authentication get helmrelease zitadel
kubectl -n authentication get httproute zitadel
kubectl -n authentication get service zitadel zitadel-login
kubectl -n authentication get cronjob zitadel-access-policy
```

For Login UI failures, inspect the `/ui/v2/login` route, Login UI service and
`zitadel-login-service-key` certificate wiring documented in the application
guide. For a rejected callback, compare the exact redirect URL and client
authentication method. For missing privileges, have an existing owner inspect
the account's administrator assignment and sign in again after a correction.

This guide does not assert that Google, local login or any application login
currently succeeds; those access cases require live verification.
