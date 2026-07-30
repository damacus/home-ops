# Tasks: External Control-Plane GitOps

## 1. Establish Recovery Inventory

- [ ] Define a machine-checkable inventory schema for external/manual state.
- [ ] Inventory every deployed service and classify its configuration, secrets,
  mutable data, generated state, and bootstrap dependencies.
- [ ] Record owners, authorities, dependencies, recovery order, verification,
  and migration status for every inventory item.
- [ ] Add CI validation that rejects incomplete inventory entries.
- [ ] Open scoped follow-up changes for non-ZITADEL provider or backup gaps.

## 2. Design State Recovery

- [ ] Compare candidate OpenTofu state backends against encryption, locking,
  versioning, independent failure-domain, and restore requirements.
- [ ] Select and document the backend and bootstrap credential authority.
- [ ] Implement state backup monitoring and recovery alerts.
- [ ] Prove state restoration into an isolated test namespace or cluster.

## 3. Install Tofu Controller

- [ ] Add a pinned Flux repository and HelmRelease for Tofu Controller.
- [ ] Add namespace, RBAC, pod security, NetworkPolicy, resource limits, and
  disruption controls.
- [ ] Expose controller metrics and alerts through existing monitoring.
- [ ] Add Flate, YAML, and Mondoo coverage for controller hardening.
- [ ] Verify a non-mutating example `Terraform` resource reaches Ready.

## 4. Prepare ZITADEL Provider

- [ ] Pin the official ZITADEL provider and OpenTofu versions.
- [ ] Deliver private-key JWT credentials through External Secrets.
- [ ] Prove provider authentication and API transport from the runner.
- [ ] Restrict runner network access to the selected ZITADEL endpoint and state
  backend.
- [ ] Verify provider and state logs cannot expose credentials or sensitive
  values.

## 5. Inventory and Import ZITADEL

- [ ] Export a read-only inventory of all live access-relevant ZITADEL
  resources.
- [ ] Map every resource ID to a Terraform address and recovery class.
- [ ] Add declarative default login policy and Google identity-provider
  resources.
- [ ] Add declarative action scripts and all action trigger bindings.
- [ ] Add supported organizations, domains, projects, applications, roles,
  grants, policies, memberships, and service identities.
- [ ] Record unsupported resources in the recovery inventory with an explicit
  API reconciler, backup, or bootstrap plan.
- [ ] Import existing resources without recreation.
- [ ] Require refresh-only and normal plans to be empty and non-destructive.

## 6. Cut Over ZITADEL Reconciliation

- [ ] Enable provider apply and confirm an idempotent reconciliation.
- [ ] Verify existing users can authenticate and unknown identities cannot
  create accounts.
- [ ] Introduce controlled drift and confirm detection, alerting, and repair.
- [ ] Compare Terraform and the interim CronJob for one full reconciliation
  interval.
- [ ] Remove the Ruby reconciler, CronJob, ConfigMap, and temporary
  NetworkPolicy allowance.
- [ ] Verify rollback does not recreate or delete ZITADEL identities.

## 7. Prove Disaster Recovery

- [ ] Restore GitOps controllers in documented dependency order.
- [ ] Restore provider state and secret references without console
  configuration.
- [ ] Restore the ZITADEL database and verify human users and identity links.
- [ ] Reconcile all declared ZITADEL resources to a no-change plan.
- [ ] Test authentication, rejection of unknown identities, actions, roles, and
  protected application access.
- [ ] Record recovery time, gaps, and follow-up work.

## 8. Operationalize Manual Change Control

- [ ] Document break-glass console access and change-record requirements.
- [ ] Alert on provider drift and stale reconciliation.
- [ ] Add a periodic review for new console-only settings across all services.
- [ ] Add a scheduled recovery exercise and require evidence before marking
  services disaster-recoverable.
