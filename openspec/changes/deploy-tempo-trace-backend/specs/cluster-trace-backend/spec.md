## Purpose

Defines a private, durable, retention-bounded trace path that lets operators query and correlate explicitly enabled MedTracker OpenTelemetry traces in the existing Grafana observability stack.

## ADDED Requirements

### Requirement: Trace ingestion is private and explicitly authorized
The cluster trace backend SHALL accept OTLP/HTTP traces only through a cluster-internal endpoint and SHALL restrict ingestion to workloads explicitly authorized for trace export.

#### Scenario: Authorized workload exports a valid trace
- **GIVEN** an authorized MedTracker workload sends a valid OTLP/HTTP trace within configured limits
- **WHEN** the trace backend accepts the request
- **THEN** the trace is available for subsequent storage and query
- **AND** acceptance does not require a public endpoint

#### Scenario: Unauthorized workload attempts ingestion
- **GIVEN** a workload is not included in the trace-ingestion policy
- **WHEN** it attempts to connect to the OTLP endpoint
- **THEN** the connection is denied
- **AND** no trace is stored

#### Scenario: External client attempts ingestion or query
- **GIVEN** a client outside the cluster
- **WHEN** it attempts to reach the OTLP or trace-query endpoint
- **THEN** neither endpoint is publicly routable

#### Scenario: Invalid trace payload is submitted
- **GIVEN** an authorized workload sends malformed or over-limit trace data
- **WHEN** the backend evaluates the request
- **THEN** the request is rejected with an observable bounded failure
- **AND** the backend remains available for valid traffic

### Requirement: Accepted traces are durable for a bounded retention window
The trace backend SHALL store accepted trace blocks in dedicated durable storage, SHALL retain them for 14 days, and SHALL delete expired blocks without sharing credentials or write authority with unrelated workloads.

#### Scenario: Backend restarts after accepting a trace
- **GIVEN** an accepted trace has been flushed to durable storage
- **WHEN** the trace-backend workload restarts
- **THEN** the trace remains queryable during its retention window

#### Scenario: Trace reaches the retention boundary
- **GIVEN** a stored trace is older than 14 days
- **WHEN** retention processing completes
- **THEN** the expired trace is no longer queryable
- **AND** storage is reclaimed according to the backend retention contract

#### Scenario: Unrelated workload requests storage credentials
- **GIVEN** a workload is not the trace backend or its storage provisioner
- **WHEN** it attempts to read the trace-storage credential
- **THEN** the credential is unavailable to that workload

#### Scenario: Durable storage becomes unavailable
- **GIVEN** the trace backend cannot write or read its durable store
- **WHEN** it handles ingestion or query traffic
- **THEN** the failure is visible through health, metrics, or alerts
- **AND** the backend does not report failed persistence as durable success

### Requirement: Operators can query and correlate traces in Grafana
Grafana SHALL provision a healthy trace data source that supports trace-ID lookup, bounded TraceQL search, trace-to-log navigation, and log-to-trace navigation through the existing Loki data source.

#### Scenario: Operator searches by trace identifier
- **GIVEN** a retained trace identifier
- **WHEN** an operator queries it in Grafana
- **THEN** Grafana displays the trace and its parent-child span structure

#### Scenario: Operator searches MedTracker traces
- **GIVEN** retained traces contain safe service and deployment resource attributes
- **WHEN** an operator runs a bounded TraceQL search for MedTracker in a selected time range
- **THEN** matching traces are returned without searching unrelated services

#### Scenario: Operator navigates from a trace to logs
- **GIVEN** a displayed span has a trace identifier and matching Loki records exist
- **WHEN** the operator follows the trace-to-logs link
- **THEN** Grafana opens a time-bounded Loki query scoped to the trace and MedTracker service

#### Scenario: Operator navigates from a log to a trace
- **GIVEN** a Loki record contains a valid retained trace identifier
- **WHEN** the operator follows the trace link
- **THEN** Grafana opens the matching trace in the trace data source

#### Scenario: Correlation metadata contains sensitive data
- **GIVEN** a trace or log record would expose medication, person, household, credential, token, cookie, request-body, or raw domain-identifier data
- **WHEN** the signal reaches Grafana
- **THEN** the prohibited value is absent
- **AND** correlation uses opaque identifiers and allowlisted attributes

### Requirement: Trace export is promoted through an exact-revision canary
MedTracker production trace export SHALL remain disabled until the exact canary image and configuration pass finite ingestion, query, correlation, privacy, and fail-open acceptance checks.

#### Scenario: Backend is ready before canary enablement
- **GIVEN** the trace backend and Grafana data source are healthy
- **WHEN** the rollout begins
- **THEN** only MedTracker canary is configured to export traces
- **AND** production remains configured with trace export disabled

#### Scenario: Canary emits a safe acceptance trace
- **GIVEN** the exact canary image is configured for OTLP/HTTP export
- **WHEN** the synthetic observability canary runs
- **THEN** its trace is queryable in Grafana within 15 minutes
- **AND** the trace contains the expected safe service, deployment, trace, span, and correlation fields
- **AND** matching Loki records link to the same trace

#### Scenario: Trace export fails during a medication operation
- **GIVEN** the backend is unavailable or rejects an export
- **WHEN** MedTracker handles a medication or health-data operation
- **THEN** the operation is not blocked, rolled back, or altered by the telemetry failure
- **AND** the failure is observable without sensitive payload data

#### Scenario: Canary acceptance fails
- **GIVEN** any required canary acceptance check fails
- **WHEN** promotion is evaluated
- **THEN** production trace export remains disabled
- **AND** rollback restores the last known-safe canary export configuration

#### Scenario: Canary acceptance passes
- **GIVEN** the finite canary acceptance matrix passes for an immutable image digest
- **WHEN** production trace export is enabled
- **THEN** production uses the same tested endpoint, protocol, privacy, and failure-isolation contract
- **AND** the deployed production digest is recorded with the acceptance evidence

### Requirement: The trace backend is operationally bounded and verifiable
The deployment SHALL have pinned dependencies, explicit resources, health checks, scrapeable backend metrics, focused repository validation, and a reversible rollout that does not depend on local Compose services.

#### Scenario: GitOps configuration is rendered
- **GIVEN** the trace backend, storage, Grafana, and MedTracker configuration changes
- **WHEN** focused repository validation runs
- **THEN** it verifies chart pinning, rendered resources, internal service ports, credentials wiring, retention, network policy, data-source configuration, and staged exporter settings

#### Scenario: Backend becomes unhealthy
- **GIVEN** the trace backend is unavailable, repeatedly restarting, rejecting spans, or failing durable storage operations
- **WHEN** cluster monitoring evaluates its health
- **THEN** operators receive a bounded actionable signal
- **AND** the signal contains no trace payload data

#### Scenario: Backend resources grow unexpectedly
- **GIVEN** trace ingestion or query load exceeds the expected low-volume envelope
- **WHEN** resource or storage limits are approached
- **THEN** the condition is observable before unbounded cluster impact
- **AND** remediation can disable MedTracker export without changing application behavior

#### Scenario: Local development starts
- **GIVEN** a developer starts the existing MedTracker Compose environment
- **WHEN** the trace-backend change has been applied to the cluster
- **THEN** no additional local Tempo, collector, or Grafana service is required by default
