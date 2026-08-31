#!/usr/bin/env bash
# Native Mise routing for the PostgreSQL blue/green operator workflow.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
export ROOT_DIR
readonly ROOT_DIR

for argument in "$@"; do
  if [[ "${argument}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    name="${argument%%=*}"
    case "${name}" in
      PG_PROFILE|NAMESPACE|APP_DEPLOYMENTS|HELMRELEASE|BLUE_CLUSTER|GREEN_CLUSTER|BLUE_DATABASE|GREEN_DATABASE|BLUE_USER|GREEN_USER|BLUE_APP_SECRET|GREEN_APP_SECRET|PUBLICATION_NAME|SUBSCRIPTION_NAME|STATE_DIR|MIGRATION_MANIFEST_DIR|HELMRELEASE_PATH|PROMETHEUS_URL|CONFIRM_CONTEXT)
        export "${argument?}"
        ;;
      *)
        printf 'unknown postgres environment assignment: %s\n' "${name}" >&2
        exit 2
        ;;
    esac
  fi
done

export PG_PROFILE="${PG_PROFILE:-}"
export NAMESPACE="${NAMESPACE:-home-automation}"
export APP_DEPLOYMENTS="${APP_DEPLOYMENTS:-n8n n8n-worker}"
export HELMRELEASE="${HELMRELEASE:-n8n}"
export BLUE_CLUSTER="${BLUE_CLUSTER:-n8n}"
export GREEN_CLUSTER="${GREEN_CLUSTER:-n8n-green}"
export BLUE_DATABASE="${BLUE_DATABASE:-app}"
export GREEN_DATABASE="${GREEN_DATABASE:-app}"
export BLUE_USER="${BLUE_USER:-app}"
export GREEN_USER="${GREEN_USER:-app}"
export BLUE_APP_SECRET="${BLUE_APP_SECRET:-n8n-app}"
export GREEN_APP_SECRET="${GREEN_APP_SECRET:-n8n-green-app}"
export PUBLICATION_NAME="${PUBLICATION_NAME:-n8n-green-pub}"
export SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-n8n-green-sub}"
export STATE_DIR="${STATE_DIR:-.migration-state/n8n}"
export MIGRATION_MANIFEST_DIR="${MIGRATION_MANIFEST_DIR:-}"
export HELMRELEASE_PATH="${HELMRELEASE_PATH:-}"
export PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus-operated.observability.svc.cluster.local:9090}"
export CONFIRM_CONTEXT="${CONFIRM_CONTEXT:-false}"

run_bluegreen() {
  "${ROOT_DIR}/scripts/pg-bluegreen.sh" "$1"
}

print_sop() {
  cat <<'EOF'
CNPG PG16 -> PG18 blue/green SOP
  0. Pick an explicit profile: PG_PROFILE=<app>
  1. Land prerequisite manifests/settings for logical replication.
  2. mise run postgres:discover PG_PROFILE=<app>
  3. mise run postgres:prepare-blue PG_PROFILE=<app>         # no-op unless the profile declares DB prerequisites
  4. mise run postgres:preflight PG_PROFILE=<app>
  5. mise run postgres:all-but-cutover PG_PROFILE=<app>
  6. mise run postgres:monitor PG_PROFILE=<app>             # repeat until ready
  7. Freeze app writes/deployments
  8. mise run postgres:ready PG_PROFILE=<app>
  9. mise run postgres:cutover PG_PROFILE=<app>             # stops writes, validates, waits
 10.   operator: commit + push the HelmRelease cutover edit and reconcile Flux
 11.   script resumes, restores replicas, runs postcheck + grafana-postcheck
 12. Soak (24-48h)
 13. mise run postgres:cleanup PG_PROFILE=<app>
EOF
}

case "${1:-}" in
  default|sop)
    print_sop
    ;;
  all-but-cutover)
    for subcommand in discover prepare-blue preflight create-green copy-schema publication subscription monitor; do
      run_bluegreen "${subcommand}"
    done
    ;;
  discover|show-active|preflight|blue-connection|green-connection|prepare-blue|create-green|copy-schema|publication|subscription|subscription-reset|monitor|ready|cutover|postcheck|grafana-postcheck|rollback|cleanup)
    run_bluegreen "$1"
    ;;
  *)
    printf 'unknown postgres task: %s\n' "${1:-}" >&2
    exit 1
    ;;
esac
