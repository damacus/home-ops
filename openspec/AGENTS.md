# OpenSpec Instructions

## Change Workflow

1. Read `proposal.md` to confirm intent and scope.
2. Review the future-state capability specs under `specs/`.
3. Read `design.md` for architecture and migration decisions.
4. Implement only approved work from `tasks.md`.
5. Mark tasks complete only after their stated verification passes.
6. Archive completed changes only after deployed behavior matches the spec.

## Safety Rules

- Import existing external resources before allowing a provider to mutate them.
- Require a no-change plan before removing an incumbent reconciler.
- Never commit secrets, provider credentials, Terraform state, or recovered
  personal data.
- Do not claim disaster recovery coverage without a restore test.
- Record unavoidable manual bootstrap work with its inputs, owner, ordering,
  verification, and rollback procedure.
