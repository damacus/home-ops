# Proposal: Add External Control-Plane GitOps

## Why

The repository can recreate Kubernetes resources, but some application
control-plane settings still exist only in service consoles or databases. PR
#3971 exposed this gap for ZITADEL: login admission, Google identity-provider
options, action deployment, and flow bindings can affect access to every
protected application without being natively represented by Kubernetes
resources.

The interim ZITADEL CronJob makes a small policy recoverable, but it is a custom
polling implementation rather than a general declarative control plane. Hidden
manual state also exists beyond ZITADEL. A cluster rebuild is not a disaster
recovery procedure if operators must remember and recreate settings by hand.

## What Changes

- Install Tofu Controller through Flux as the reconciler for supported external
  APIs.
- Add a pinned official ZITADEL provider configuration and adopt existing
  ZITADEL resources into managed state without recreating them.
- Replace the interim Ruby/CronJob policy reconciler after Terraform reaches a
  no-change plan and demonstrates equivalent enforcement.
- Inventory all manually configured service state and assign every item an
  authoritative recovery mechanism.
- Require declarative reconciliation for configuration supported by a provider
  or API controller.
- Require external secret authority for credentials and independent,
  restore-tested backups for mutable application data.
- Document and minimize unavoidable bootstrap operations rather than leaving
  them as tribal knowledge.
- Add drift detection, recovery ordering, and periodic restoration tests.

## Capabilities

### New Capability: External Control-Plane GitOps

The system will continuously reconcile supported external service
configuration from reviewed Git state and detect out-of-band changes.

### New Capability: Configuration Recovery Inventory

The system will maintain a machine-checkable inventory showing how every
manually created or externally persisted setting can be reconstructed,
reconciled, or restored.

## Scope

The first implementation covers Tofu Controller and all access-relevant
ZITADEL configuration, including the default login policy, Google identity
provider, action scripts, action trigger bindings, organizations, projects,
applications, roles, grants, and service identities where supported.

The inventory covers every deployed service. Subsequent implementation may
split provider migrations into separate reviewed changes, but uncovered manual
state cannot be silently accepted.

## Boundaries

- Human users, linked identities, sessions, audit events, and other mutable
  service data are not automatically converted into Terraform resources.
  Their authority is the ZITADEL database and its tested backup/restore path.
- Credentials and private material remain outside Git and are injected through
  External Secrets or an equivalent declared secret reference.
- Provider gaps do not justify undocumented console state. Each gap requires a
  tracked API reconciler, backup contract, or explicit bootstrap runbook.
- This change does not authorize destructive imports, account recreation, or
  deletion of duplicate user records.

## Impact

- New Flux-managed controller, CRDs, RBAC, network policy, monitoring, and
  provider execution workloads.
- New remote or independently recoverable OpenTofu state and locking.
- New inventory and policy checks in CI.
- Migration of existing ZITADEL resources from console ownership to imported
  provider ownership.
- Removal of the interim ZITADEL Ruby reconciler only after parity is proven.
