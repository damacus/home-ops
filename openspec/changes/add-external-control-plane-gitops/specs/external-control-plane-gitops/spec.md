# External Control-Plane GitOps Specification

## Purpose

This capability ensures that service configuration outside the Kubernetes API
is reviewable, continuously reconciled or recoverable, and included in tested
disaster recovery.

## ADDED Requirements

### Requirement: Complete configuration inventory

The system SHALL maintain a machine-checkable inventory of every setting or
resource created through a service console, API, CLI, database migration, or
other operation outside normal Flux reconciliation.

#### Scenario: A manual setting is discovered

- **GIVEN** an operator discovers a setting created outside Git reconciliation
- **WHEN** the service inventory is updated
- **THEN** the setting SHALL identify its authoritative source
- **AND** it SHALL identify its recovery class, owner, dependencies,
  verification method, and recovery order
- **AND** console-only state without a tracked exception SHALL fail inventory
  validation

#### Scenario: A new service is introduced

- **WHEN** a service is proposed for deployment
- **THEN** its control-plane configuration, secrets, mutable data, generated
  state, and bootstrap dependencies SHALL be inventoried before production use

### Requirement: Explicit recovery authority

Every inventory item SHALL use exactly one primary authority: reviewed Git,
an external secret authority, a restore-tested datastore backup, deterministic
generator inputs, or an explicit bootstrap procedure.

#### Scenario: Configuration belongs in Git

- **GIVEN** an external API supports declarative management
- **WHEN** the setting affects production behavior or access
- **THEN** reviewed Git SHALL contain its desired non-secret state
- **AND** a declared controller SHALL reconcile that state

#### Scenario: Data does not belong in Git

- **GIVEN** a resource is mutable application data, personal data, secret
  material, or provider state
- **WHEN** its recovery authority is assigned
- **THEN** the data SHALL remain outside Git
- **AND** Git SHALL declare or document its backup, secret reference, or
  deterministic recovery mechanism

### Requirement: Flux-managed external reconciliation

Flux SHALL manage the lifecycle and desired configuration of the controller
that reconciles supported external APIs.

#### Scenario: Tofu Controller operates normally

- **GIVEN** Flux has reconciled the controller and a `Terraform` resource
- **WHEN** desired external configuration changes in Git
- **THEN** Tofu Controller SHALL produce a plan and reconcile the approved
  change
- **AND** controller, provider, and OpenTofu versions SHALL be pinned

#### Scenario: External state drifts

- **GIVEN** an external resource differs from reviewed Git
- **WHEN** the periodic refresh runs without a Git change
- **THEN** the system SHALL detect the drift
- **AND** it SHALL alert and reconcile or block according to the approved apply
  policy

### Requirement: Recoverable provider state

OpenTofu state SHALL be encrypted, versioned, locked against concurrent writes,
and recoverable independently of the workload cluster.

#### Scenario: The cluster is lost

- **GIVEN** the Kubernetes cluster and in-cluster Secrets are unavailable
- **WHEN** operators rebuild the GitOps control plane
- **THEN** they SHALL recover the latest valid provider state from its
  documented authority
- **AND** a subsequent plan SHALL not propose recreating adopted external
  resources

#### Scenario: State recovery is tested

- **WHEN** the scheduled disaster-recovery exercise runs
- **THEN** state SHALL be restored into an isolated environment
- **AND** backend integrity, locking, credentials, and a no-change plan SHALL be
  verified

### Requirement: Safe adoption of existing resources

Existing external resources SHALL be imported and verified before provider
apply is enabled.

#### Scenario: A live resource is adopted

- **GIVEN** a live resource has a proposed Terraform address
- **WHEN** it is imported
- **THEN** refresh-only and normal plans SHALL be non-destructive
- **AND** the normal plan SHALL be empty before automated apply is enabled

#### Scenario: Import would recreate identity state

- **GIVEN** a plan proposes deleting or recreating an existing user, identity
  provider, project, application, grant, or service identity
- **WHEN** the migration gate evaluates the plan
- **THEN** apply SHALL be blocked
- **AND** the mismatch SHALL require explicit review

### Requirement: Declarative ZITADEL access policy

The official ZITADEL provider SHALL manage all supported settings that affect
authentication or authorization.

#### Scenario: Account admission is reconciled

- **GIVEN** the default login policy and Google identity provider are imported
- **WHEN** provider reconciliation completes
- **THEN** local registration SHALL be disabled
- **AND** Google automatic and manual account creation SHALL be disabled
- **AND** existing-account linking and approved updates SHALL retain their
  reviewed behavior

#### Scenario: Token actions are recovered

- **GIVEN** action source and trigger bindings are declared in Git
- **WHEN** ZITADEL is restored or the action drifts
- **THEN** the provider SHALL restore the reviewed action code
- **AND** it SHALL restore every required token trigger binding

#### Scenario: Provider coverage is incomplete

- **GIVEN** a ZITADEL setting is not supported by the pinned provider
- **WHEN** the inventory records the gap
- **THEN** the setting SHALL have a tracked API reconciler, database recovery
  contract, or explicit bootstrap procedure
- **AND** it SHALL not remain undocumented console state

### Requirement: Secret separation

Provider credentials and application secrets SHALL be referenced from an
external secret authority and SHALL NOT be committed to Git or exposed in
plans, logs, or state outputs.

#### Scenario: The provider authenticates

- **GIVEN** the external secret authority contains a scoped ZITADEL service
  identity key
- **WHEN** External Secrets projects the credential to the provider runner
- **THEN** the provider SHALL authenticate without a personal access token
- **AND** network policy SHALL limit the runner to required endpoints

#### Scenario: A write-only provider secret is managed

- **GIVEN** a provider resource requires a write-only client secret
- **WHEN** the value is supplied to OpenTofu
- **THEN** the value SHALL come from the external secret authority
- **AND** plan output, logs, inventory, and Git SHALL not reveal it

### Requirement: Mutable identity data recovery

Human users, linked identities, sessions, and other mutable ZITADEL data SHALL
be recovered through the ZITADEL datastore backup unless separately approved as
declarative resources.

#### Scenario: ZITADEL is restored after loss

- **GIVEN** a valid ZITADEL database backup and declared control-plane
  configuration
- **WHEN** the disaster-recovery procedure runs
- **THEN** existing human users and linked identities SHALL be restored from
  the database
- **AND** provider reconciliation SHALL restore or verify control-plane
  settings without duplicating users

### Requirement: Auditable emergency changes

Emergency external changes SHALL be temporary, attributable, and reconciled
back to reviewed state.

#### Scenario: Break-glass console access is used

- **WHEN** an operator changes a managed setting through a console or direct API
- **THEN** the change SHALL reference an incident or change record
- **AND** drift detection SHALL report it
- **AND** the incident SHALL not close until Git adopts the change or the
  external state is reverted

### Requirement: End-to-end recovery evidence

A service SHALL NOT be marked disaster-recoverable until its documented
authorities have been restored and its user-visible behavior verified.

#### Scenario: Recovery exercise completes

- **WHEN** the recovery exercise finishes
- **THEN** it SHALL record the restored Git revision, secret references, state
  version, datastore backup, reconciliation results, validation results, and
  elapsed recovery time
- **AND** unresolved gaps SHALL create tracked follow-up work
