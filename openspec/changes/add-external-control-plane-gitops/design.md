# Design: External Control-Plane GitOps

## Context

Flux reconciles Kubernetes API objects. ZITADEL login policies, identity
providers, actions, and trigger bindings are persisted through the ZITADEL API,
so a plain YAML file has no effect unless a controller understands it.

The official ZITADEL Terraform provider supports resources needed by the first
migration, including default login policies, Google identity providers,
actions, and action trigger bindings. Tofu Controller provides the missing
Flux-compatible reconciliation loop for Terraform/OpenTofu resources.

## Goals

- Make Git the reviewable authority for external control-plane configuration.
- Recover access-critical settings without console knowledge.
- Detect and repair unauthorized drift.
- Adopt existing resources without duplication or interruption.
- Keep secrets and mutable user data out of Git.
- Make the full system recovery order explicit and testable.

## Non-Goals

- Treating all database rows as infrastructure resources.
- Replacing application-native backup and restore mechanisms.
- Recreating or deduplicating ZITADEL human users during provider adoption.
- Storing OpenTofu state or provider credentials in Git.
- Removing all emergency administrative access.

## Technical Approach

### Architecture

```text
Git
  |
  v
Flux Kustomization and HelmRelease
  |
  v
Tofu Controller ---- independently recoverable state backend
  |
  +---- External Secret references
  |
  v
Official ZITADEL provider
  |
  v
ZITADEL API and persisted configuration
```

Flux remains responsible for controller installation and the `Terraform`
custom resource. Tofu Controller is responsible for planning, applying, and
periodically refreshing external state. The ZITADEL provider is responsible for
translating declarative resources into API operations.

## Configuration Classification

Each discovered manual item must be assigned exactly one primary recovery
class:

| Class | Authority | Recovery mechanism |
| --- | --- | --- |
| Declarative configuration | Git | Flux, Tofu Controller, or another declared controller |
| Secret material | External secret authority | External Secrets plus documented bootstrap |
| Mutable application data | Service datastore | Versioned backup and tested restore |
| Generated state | Declared generator inputs | Deterministic regeneration or backed-up state |
| Bootstrap dependency | Runbook and automation | Ordered, verified, minimal manual procedure |

An inventory entry records the service, resource or setting, class, authority,
reconciler or backup, secret reference, dependencies, verification method,
recovery order, and migration status. CI rejects incomplete entries and
console-only configuration without an approved exception.

## Tofu Controller

Tofu Controller will be installed by a pinned Flux source and HelmRelease. Its
CRDs, controller image, provider versions, service account, RBAC, network
policy, resource limits, metrics, alerts, and upgrade policy will be explicit
in Git.

Provider runners receive only the credentials and network access needed for
their target. Plans run on a fixed interval and after Git changes. Apply
behavior must prevent concurrent runs and expose plan/apply failures through
existing monitoring.

## State and Disaster Recovery

The sole copy of OpenTofu state must not live only inside the Kubernetes cluster
it is expected to rebuild. Before adoption, implementation must select a
versioned, encrypted backend with locking and an independently testable recovery
path, or prove that the Kubernetes state copy is captured by a backup outside
the cluster failure domain.

State recovery documentation must identify bootstrap credentials, backend
location, encryption authority, lock recovery, restore commands, and validation
steps. A clean-cluster exercise must prove the controller can recover state and
produce a no-change plan.

## ZITADEL Provider

The provider version will be pinned. Authentication will use a declared
service identity and key delivered from the external secret authority; PATs
will not be introduced. Provider connectivity must be proven from its in-cluster
runner before imports begin.

The current public route has previously failed for provider gRPC traffic, so
implementation must test one of these supported paths:

- the public ZITADEL endpoint with required proxy and transport headers; or
- the internal service with correct instance routing, audience, and transport
  security.

The chosen route must use narrow NetworkPolicy rules and must not disable TLS
verification for external traffic.

## ZITADEL Adoption

Adoption starts with a read-only inventory of the live instance and a mapping
from each resource ID to a proposed Terraform address. At minimum, the audit
includes:

- instance default login policy and active identity providers;
- Google provider settings and its secret reference;
- organizations, domains, projects, applications, roles, and grants;
- machine users, keys, instance and organization memberships;
- action scripts and every trigger binding;
- branding, notification, password, lockout, privacy, and domain policies;
- manually assigned user metadata or role grants that affect authorization.

Existing resources are imported; they are not recreated. Configuration is
expanded to include all provider-required fields so the first post-import plan
is empty. Sensitive write-only fields use secret inputs and provider-supported
hash handling.

Human users and linked external identities remain application data unless a
separate reviewed decision makes specific service identities declarative.
Their recovery is proven through ZITADEL database restoration.

## Migration

1. Install and observe Tofu Controller without granting ZITADEL mutation
   credentials.
2. Establish and restore-test the state backend.
3. Inventory live ZITADEL resources and secret dependencies.
4. Author pinned provider configuration and import declarations.
5. Run refresh-only and normal plans until both are non-destructive and empty.
6. Enable apply and verify access for existing users plus rejection of an
   unknown Google identity.
7. Run the interim CronJob and Terraform in comparison mode for at least one
   reconciliation interval.
8. Remove the Ruby script, policy ConfigMap, CronJob, and its NetworkPolicy
   allowance only after parity and rollback evidence are recorded.
9. Restore ZITADEL and provider state in an isolated recovery exercise.

## Drift and Break-Glass Changes

Periodic refresh detects console changes even when Git does not change. Drift
creates an alert and is reconciled according to the approved apply mode.

Emergency console changes require a tracked incident or change record. Before
the incident closes, the operator must either encode the change in Git or
explicitly revert it. Permanent ignore rules require review and a documented
recovery owner.

## Failure Handling

- A provider or state-backend outage must not disrupt ZITADEL authentication.
- A failed or destructive plan must block apply and alert.
- One external target failing must not corrupt another target's state.
- Controller removal must leave externally managed resources intact.
- Loss of Git, cluster, state backend, secret authority, or ZITADEL database
  must have an explicit recovery ordering and verification checkpoint.

## Open Decisions

- Select the state backend and independent backup location.
- Confirm the provider transport path compatible with the deployed ZITADEL and
  proxy topology.
- Define the initial inventory schema and CI validator implementation.
- Select the first non-ZITADEL services for manual-state discovery.
