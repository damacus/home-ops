#!/usr/bin/env bash
# pg-bluegreen.sh — orchestrator for CNPG PG16 -> PG18 blue/green migrations.
#
# Invoked by .taskfiles/Postgres/Taskfile.yaml. Each subcommand is idempotent.
# Required tools on PATH: kubectl, flux, helm, yq, jq, base64, awk, sed.
#
# Configuration: all knobs come from environment variables (set by the
# Taskfile or loaded from .env at repo root). See .env.sample for the full
# list and defaults.
set -Eeuo pipefail
shopt -s inherit_errexit

# ----------------------------------------------------------------------------
# Bootstrap
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="${ROOT_DIR:-$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.env"
  set +a
fi

# Optional app profile. Use this for service-specific wiring such as Helm value
# paths, deployment names, and secret key shapes.
: "${PG_PROFILE:=}"
if [[ -n "${PG_PROFILE}" ]]; then
  profile_file="${REPO_ROOT}/.taskfiles/Postgres/profiles/${PG_PROFILE}.env"
  [[ -f "${profile_file}" ]] || {
    printf '[pg-bg] profile not found: %s\n' "${profile_file}" >&2
    exit 1
  }
  set -a
  # shellcheck disable=SC1090
  . "${profile_file}"
  set +a
fi

# Required env, with conservative defaults that target the historical n8n
# migration. Prefer PG_PROFILE or explicit task vars for any new migration.
: "${NAMESPACE:=home-automation}"
: "${APP_DEPLOYMENTS:=n8n n8n-worker}"
: "${APP_WORKLOADS:=}"
: "${HELMRELEASE:=n8n}"
: "${BLUE_CLUSTER:=n8n}"
: "${GREEN_CLUSTER:=n8n-green}"
: "${BLUE_DATABASE:=app}"
: "${GREEN_DATABASE:=app}"
: "${BLUE_USER:=app}"
: "${GREEN_USER:=app}"
: "${BLUE_APP_SECRET:=n8n-app}"
: "${GREEN_APP_SECRET:=n8n-green-app}"
: "${PUBLICATION_NAME:=n8n-green-pub}"
: "${SUBSCRIPTION_NAME:=n8n-green-sub}"
: "${PUBLICATION_PG_NAME:=${PUBLICATION_NAME//-/_}}"
: "${SUBSCRIPTION_PG_NAME:=${SUBSCRIPTION_NAME//-/_}}"
: "${STATE_DIR:=.migration-state/n8n}"
: "${MIGRATION_MANIFEST_DIR:=${REPO_ROOT}/kubernetes/apps/home-automation/n8n-db/migration}"
: "${HELMRELEASE_PATH:=${REPO_ROOT}/kubernetes/apps/home-automation/n8n/app/helmrelease.yaml}"
: "${CUTOVER_TARGET_TYPE:=secret-anchor}" # secret-anchor | helm-value | secret-key | none
: "${HELM_VALUE_PATH:=}"
: "${BLUE_HELM_VALUE:=}"
: "${GREEN_HELM_VALUE:=}"
: "${CUTOVER_FILE_PATH:=}"
: "${YAML_VALUE_PATH:=}"
: "${CUTOVER_SECRET_NAME:=}"
: "${CUTOVER_SECRET_KEY:=}"
: "${REQUIRED_APP_SECRET_KEYS:=host user password dbname}"
: "${REPLICA_IDENTITY_FULL_TABLES:=}"
: "${ROWCOUNT_EXCLUDE_TABLES:=}"
if [[ ! ${POSTCHECK_ENV_VAR+x} ]]; then POSTCHECK_ENV_VAR=DB_POSTGRESDB_HOST; fi
if [[ ! ${APP_POD_SELECTOR+x} ]]; then APP_POD_SELECTOR=; fi
if [[ ! ${PROM_POD_REGEX+x} ]]; then PROM_POD_REGEX="${HELMRELEASE}.*"; fi
if [[ ! ${REQUIRE_APP_CONNECTIONS+x} ]]; then REQUIRE_APP_CONNECTIONS=true; fi
: "${READY_LAG_BYTES:=1048576}"   # 1 MiB
: "${BACKUP_WAIT_TIMEOUT:=600}"
: "${CUTOVER_WAIT_TIMEOUT:=600}"
: "${PROMETHEUS_URL:=http://prometheus-operated.observability.svc.cluster.local:9090}"
: "${HEALTH_URL:=https://n8n.ironstone.casa/healthz}"
: "${CONFIRM_CONTEXT:=false}"
: "${FORCE_SCHEMA:=false}"
: "${SCHEMA_REWRITE_UNLOGGED_TABLES:=false}"
: "${ACCEPT_DATA_LOSS:=false}"
: "${GRAFANA_MCP_ENABLED:=false}"

STATE_DIR_ABS="${REPO_ROOT}/${STATE_DIR}"
CUTOVER_STATE_FILE="${STATE_DIR_ABS}/cutover.json"
mkdir -p "${STATE_DIR_ABS}"

# ----------------------------------------------------------------------------
# Output / error helpers
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN_C=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE_C=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN_C=""; YELLOW=""; BLUE_C=""; RESET=""
fi

log()  { printf '%s[pg-bg]%s %s\n' "${BLUE_C}" "${RESET}" "$*" >&2; }
warn() { printf '%s[pg-bg]%s %s%s%s\n' "${BLUE_C}" "${RESET}" "${YELLOW}" "$*" "${RESET}" >&2; }
err()  { printf '%s[pg-bg]%s %s%s%s\n' "${BLUE_C}" "${RESET}" "${RED}" "$*" "${RESET}" >&2; }
ok()   { printf '%s[pg-bg]%s %s%s%s\n' "${BLUE_C}" "${RESET}" "${GREEN_C}" "$*" "${RESET}" >&2; }

die()  { err "$*"; exit 1; }

indent_stderr() { sed 's/^/    /' >&2; }

on_err() {
  local line=$1 cmd=$2
  err "failed at line ${line}: ${cmd}"
}
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

# ----------------------------------------------------------------------------
# kubectl / SQL helpers
# ----------------------------------------------------------------------------

require_tools() {
  local missing=()
  for tool in kubectl yq jq base64 awk sed; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  if (( ${#missing[@]} > 0 )); then
    die "missing required tools: ${missing[*]}"
  fi
}

kctl() { kubectl -n "${NAMESPACE}" "$@"; }

app_workloads() {
  if [[ -n "${APP_WORKLOADS}" ]]; then
    printf '%s\n' ${APP_WORKLOADS}
    return 0
  fi

  local deploy
  for deploy in ${APP_DEPLOYMENTS}; do
    printf 'deployment/%s\n' "${deploy}"
  done
}

workload_state_key() {
  local workload=$1
  printf '%s' "${workload//\//_}"
}

primary_pod() {
  local cluster=$1
  kctl get pod -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
    || kctl get pod -l "cnpg.io/cluster=${cluster},role=primary" \
        -o jsonpath='{.items[0].metadata.name}'
}

cluster_exists() {
  local cluster=$1
  kctl get cluster "${cluster}" >/dev/null 2>&1
}

# Exec psql inside a CNPG primary pod using the superuser secret mounted as
# /controller/credentials/superuser. Reads SQL from stdin or first arg.
psql_as_super() {
  local cluster=$1 dbname=$2 sql=$3
  local pod
  pod=$(primary_pod "${cluster}")
  kctl exec -c postgres "${pod}" -- bash -lc "psql -t -A -X -v ON_ERROR_STOP=1 -d '${dbname}' -c \"${sql//\"/\\\"}\""
}

psql_as_super_stdin() {
  local cluster=$1 dbname=$2
  local pod
  pod=$(primary_pod "${cluster}")
  kctl exec -i -c postgres "${pod}" -- bash -lc "psql -X -v ON_ERROR_STOP=1 -d '${dbname}'"
}

validate_identifier() {
  local name=$1 value=$2
  [[ "${value}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "${name} must be a simple PostgreSQL identifier, got '${value}'"
}

helmrelease_anchor() {
  grep -E '&dbSecret[[:space:]]+' "${HELMRELEASE_PATH}" \
    | head -n1 | sed -E 's/.*&dbSecret[[:space:]]+([^[:space:]]+).*/\1/'
}

first_yaml_value() {
  sed '/^[[:space:]]*$/d' | head -n1
}

repo_cutover_target() {
  case "${CUTOVER_TARGET_TYPE}" in
    secret-anchor)
      helmrelease_anchor
      ;;
    helm-value)
      [[ -n "${HELM_VALUE_PATH}" ]] || die "HELM_VALUE_PATH is required for CUTOVER_TARGET_TYPE=helm-value"
      yq -rN "${HELM_VALUE_PATH}" "${HELMRELEASE_PATH}" | first_yaml_value
      ;;
    secret-key)
      [[ -n "${CUTOVER_FILE_PATH}" ]] || die "CUTOVER_FILE_PATH is required for CUTOVER_TARGET_TYPE=secret-key"
      [[ -n "${YAML_VALUE_PATH}" ]] || die "YAML_VALUE_PATH is required for CUTOVER_TARGET_TYPE=secret-key"
      yq -rN "${YAML_VALUE_PATH}" "${CUTOVER_FILE_PATH}" | first_yaml_value
      ;;
    none)
      echo ""
      ;;
    *)
      die "unknown CUTOVER_TARGET_TYPE='${CUTOVER_TARGET_TYPE}'"
      ;;
  esac
}

repo_cutover_file() {
  case "${CUTOVER_TARGET_TYPE}" in
    secret-anchor|helm-value)
      echo "${HELMRELEASE_PATH}"
      ;;
    secret-key)
      echo "${CUTOVER_FILE_PATH}"
      ;;
    none)
      echo ""
      ;;
    *)
      die "unknown CUTOVER_TARGET_TYPE='${CUTOVER_TARGET_TYPE}'"
      ;;
  esac
}

live_cutover_target() {
  case "${CUTOVER_TARGET_TYPE}" in
    secret-anchor)
      kctl get helmrelease "${HELMRELEASE}" -o yaml 2>/dev/null \
        | yq -r '.spec.values.controllers.n8n.containers.app.env.DB_POSTGRESDB_DATABASE.valueFrom.secretKeyRef.name // ""'
      ;;
    helm-value)
      [[ -n "${HELM_VALUE_PATH}" ]] || die "HELM_VALUE_PATH is required for CUTOVER_TARGET_TYPE=helm-value"
      kctl get helmrelease "${HELMRELEASE}" -o yaml 2>/dev/null \
        | yq -rN "${HELM_VALUE_PATH}" - | first_yaml_value
      ;;
    secret-key)
      [[ -n "${CUTOVER_SECRET_NAME}" ]] || die "CUTOVER_SECRET_NAME is required for CUTOVER_TARGET_TYPE=secret-key"
      [[ -n "${CUTOVER_SECRET_KEY}" ]] || die "CUTOVER_SECRET_KEY is required for CUTOVER_TARGET_TYPE=secret-key"
      kctl get secret "${CUTOVER_SECRET_NAME}" -o jsonpath="{.data.${CUTOVER_SECRET_KEY}}" 2>/dev/null \
        | base64 -d
      ;;
    none)
      echo ""
      ;;
    *)
      die "unknown CUTOVER_TARGET_TYPE='${CUTOVER_TARGET_TYPE}'"
      ;;
  esac
}

blue_cutover_target() {
  case "${CUTOVER_TARGET_TYPE}" in
    secret-anchor) echo "${BLUE_APP_SECRET}" ;;
    helm-value)   echo "${BLUE_HELM_VALUE}" ;;
    secret-key)   echo "${BLUE_HELM_VALUE}" ;;
    none)         echo "" ;;
  esac
}

green_cutover_target() {
  case "${CUTOVER_TARGET_TYPE}" in
    secret-anchor) echo "${GREEN_APP_SECRET}" ;;
    helm-value)   echo "${GREEN_HELM_VALUE}" ;;
    secret-key)   echo "${GREEN_HELM_VALUE}" ;;
    none)         echo "" ;;
  esac
}

set_repo_cutover_target() {
  local target=$1
  case "${CUTOVER_TARGET_TYPE}" in
    secret-anchor)
      die "secret-anchor cutover still requires a manual YAML anchor edit"
      ;;
    helm-value)
      [[ -n "${HELM_VALUE_PATH}" ]] || die "HELM_VALUE_PATH is required for CUTOVER_TARGET_TYPE=helm-value"
      yq -i "${HELM_VALUE_PATH} = \"${target}\"" "${HELMRELEASE_PATH}"
      ;;
    secret-key)
      [[ -n "${CUTOVER_FILE_PATH}" ]] || die "CUTOVER_FILE_PATH is required for CUTOVER_TARGET_TYPE=secret-key"
      [[ -n "${YAML_VALUE_PATH}" ]] || die "YAML_VALUE_PATH is required for CUTOVER_TARGET_TYPE=secret-key"
      yq -i "${YAML_VALUE_PATH} = \"${target}\"" "${CUTOVER_FILE_PATH}"
      ;;
    none)
      ;;
  esac
}

save_cutover_stage() {
  local state_file=$1 stage=$2
  local tmp="${state_file}.tmp"
  jq --arg stage "${stage}" '.stage = $stage' "${state_file}" >"${tmp}"
  mv "${tmp}" "${state_file}"
}

restore_app_replicas() {
  local state_file=$1
  local workload key
  while read -r workload; do
    [[ -n "${workload}" ]] || continue
    key=$(workload_state_key "${workload}")
    local r
    r=$(jq -r ".replicas.\"${key}\"" "${state_file}")
    [[ "${r}" == "0" || "${r}" == "null" ]] && r=1
    kctl scale "${workload}" --replicas="${r}"
  done < <(app_workloads)
  while read -r workload; do
    [[ -n "${workload}" ]] || continue
    kctl rollout status "${workload}" --timeout=300s
  done < <(app_workloads)
}

resume_cutover_after_handoff() {
  local state_file=$1
  local target expected cutover_file
  target=$(repo_cutover_target)
  expected=$(green_cutover_target)
  cutover_file=$(repo_cutover_file)
  [[ "${target}" == "${expected}" ]] \
    || die "cutover target in ${cutover_file:-repo} is '${target}', expected '${expected}'. App may still be scaled to 0; complete the cutover edit or rollback."

  log "restoring app replica counts"
  restore_app_replicas "${state_file}"

  cmd_postcheck
  cmd_grafana_postcheck || warn "grafana-postcheck reported issues; review manually"
  save_cutover_stage "${state_file}" "complete"
  rm -f "${STATE_DIR_ABS}/proceed"
  ok "cutover sequence complete"
}

# ----------------------------------------------------------------------------
# Subcommand: discover
# ----------------------------------------------------------------------------

cmd_discover() {
  require_tools
  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  local log_file="${STATE_DIR_ABS}/discover-${ts}.log"

  {
    echo "=== kubectl context ==="
    kubectl config current-context
    echo

    echo "=== CNPG operator ==="
    kubectl -n cnpg-system get deploy -o wide 2>/dev/null \
      || kubectl get deploy -A -l app.kubernetes.io/name=cloudnative-pg
    echo

    echo "=== CNPG CRDs ==="
    for crd in clusters.postgresql.cnpg.io publications.postgresql.cnpg.io \
               subscriptions.postgresql.cnpg.io; do
      if kubectl get crd "${crd}" >/dev/null 2>&1; then
        echo "  present: ${crd}"
      else
        echo "  MISSING: ${crd}"
      fi
    done
    echo

    echo "=== Namespace state (${NAMESPACE}) ==="
    kctl get cluster,publication,subscription,deploy,svc 2>/dev/null || true
    echo

    echo "=== HelmRelease ${HELMRELEASE} active cutover target ==="
    echo "live: $(live_cutover_target 2>/dev/null || true)"
    echo "repo: $(repo_cutover_target 2>/dev/null || true)"
    echo

    if cluster_exists "${BLUE_CLUSTER}"; then
      echo "=== Blue (${BLUE_CLUSTER}) ==="
      kctl get cluster "${BLUE_CLUSTER}" -o yaml | yq '.status // {}'
      echo "--- SQL: version ---"
      psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SELECT version();" || true
      echo "--- SQL: db size ---"
      psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
        "SELECT pg_size_pretty(pg_database_size(current_database()));" || true
      echo "--- SQL: extensions ---"
      psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
        "SELECT extname, extversion FROM pg_extension ORDER BY extname;" || true
      echo "--- SQL: top 20 tables ---"
      psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SELECT
        schemaname || '.' || relname AS rel,
        pg_size_pretty(pg_total_relation_size(format('%I.%I', schemaname, relname)::regclass)) AS size
      FROM pg_stat_user_tables
      ORDER BY pg_total_relation_size(format('%I.%I', schemaname, relname)::regclass) DESC
      LIMIT 20;" || true
      echo
    else
      echo "Blue cluster ${BLUE_CLUSTER} not found in namespace ${NAMESPACE}."
    fi

    echo "=== Blue app secret (${BLUE_APP_SECRET}) keys ==="
    kctl get secret "${BLUE_APP_SECRET}" -o jsonpath='{.data}' 2>/dev/null \
      | jq -r 'keys[]' || warn "secret ${BLUE_APP_SECRET} not present"
    echo

    if cluster_exists "${GREEN_CLUSTER}"; then
      echo "=== Green (${GREEN_CLUSTER}) ==="
      kctl get cluster "${GREEN_CLUSTER}" -o yaml | yq '.status // {}'
      echo
    else
      echo "Green cluster ${GREEN_CLUSTER} not yet present."
    fi
  } | tee "${log_file}"

  ok "discover snapshot written to ${log_file}"
}

# ----------------------------------------------------------------------------
# Subcommand: show-active
# ----------------------------------------------------------------------------

cmd_show_active() {
  require_tools
  local live repo
  live=$(live_cutover_target 2>/dev/null || true)
  repo=$(repo_cutover_target 2>/dev/null || true)
  echo "profile: ${PG_PROFILE:-<none>}"
  echo "type: ${CUTOVER_TARGET_TYPE}"
  echo "in-cluster: ${live:-<none>}"
  echo "in-repo: ${repo:-<none>}"
}

# ----------------------------------------------------------------------------
# Subcommand: blue-connection / green-connection
# ----------------------------------------------------------------------------

cmd_connection() {
  local secret=$1
  kctl get secret "${secret}" -o jsonpath='{.data.uri}' 2>/dev/null \
    | base64 -d \
    || die "secret ${secret} or key 'uri' not found in namespace ${NAMESPACE}"
  echo
}

# ----------------------------------------------------------------------------
# Subcommand: preflight
# ----------------------------------------------------------------------------

cmd_preflight() {
  require_tools
  local fail=0

  log "kubectl context check"
  local current_context
  current_context=$(kubectl config current-context)
  if [[ "${CONFIRM_CONTEXT}" != "true" ]]; then
    warn "kubectl context = ${current_context}. Set CONFIRM_CONTEXT=true once verified."
    fail=1
  else
    ok "context confirmed: ${current_context}"
  fi

  log "CRD presence check"
  for crd in clusters.postgresql.cnpg.io publications.postgresql.cnpg.io \
             subscriptions.postgresql.cnpg.io; do
    if ! kubectl get crd "${crd}" >/dev/null 2>&1; then
      err "missing CRD: ${crd}"
      fail=1
    fi
  done

  log "blue cluster health"
  if ! cluster_exists "${BLUE_CLUSTER}"; then
    err "blue cluster ${BLUE_CLUSTER} not found in ${NAMESPACE}"
    fail=1
  else
    local phase
    phase=$(kctl get cluster "${BLUE_CLUSTER}" -o jsonpath='{.status.phase}' || echo "")
    if [[ "${phase}" != "Cluster in healthy state" ]]; then
      err "blue cluster phase = '${phase}', expected 'Cluster in healthy state'"
      fail=1
    fi
  fi

  if [[ "${fail}" -eq 0 ]]; then
    log "blue postgresql.parameters check (wal_level, slots, senders)"
    local wal_level slots senders
    wal_level=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SHOW wal_level;" | tr -d '[:space:]')
    slots=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SHOW max_replication_slots;" | tr -d '[:space:]')
    senders=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SHOW max_wal_senders;" | tr -d '[:space:]')
    [[ "${wal_level}" == "logical" ]] || { err "wal_level=${wal_level}, need 'logical'"; fail=1; }
    [[ "${slots}" -ge 10 ]] || { err "max_replication_slots=${slots}, need >=10"; fail=1; }
    [[ "${senders}" -ge 10 ]] || { err "max_wal_senders=${senders}, need >=10"; fail=1; }

    log "primary key presence on user tables"
    local missing_pk
    missing_pk=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SELECT
      n.nspname || '.' || c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND c.relreplident <> 'f'
      AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary);")
    if [[ -n "${missing_pk}" ]]; then
      err "tables without primary keys (logical replication needs PKs or REPLICA IDENTITY FULL):"
      printf '%s\n' "${missing_pk}" | indent_stderr
      fail=1
    fi
  fi

  log "blue replication slot synchronization"
  local slot_sync
  slot_sync=$(kctl get cluster "${BLUE_CLUSTER}" \
    -o jsonpath='{.spec.replicationSlots.synchronizeReplicas.enabled}' 2>/dev/null || echo "")
  if [[ "${slot_sync}" != "true" ]]; then
    err "blue cluster does not have replicationSlots.synchronizeReplicas.enabled=true"
    err "logical replication cutover would be unsafe across blue failover; enable slot synchronization or avoid failover during migration"
    fail=1
  fi

  log "blue app secret shape check"
  local present_keys
  present_keys=$(kctl get secret "${BLUE_APP_SECRET}" -o jsonpath='{.data}' 2>/dev/null \
    | jq -r 'keys | join(",")' || echo "")
  if [[ -z "${present_keys}" ]]; then
    err "secret ${BLUE_APP_SECRET} not found"
    fail=1
  else
    for required in ${REQUIRED_APP_SECRET_KEYS}; do
      if ! [[ ",${present_keys}," == *",${required},"* ]]; then
        err "secret ${BLUE_APP_SECRET} missing key '${required}' (have: ${present_keys})"
        fail=1
      fi
    done
  fi

  log "cutover target points at blue"
  local target expected_blue
  target=$(repo_cutover_target)
  expected_blue=$(blue_cutover_target)
  if [[ "${target}" != "${expected_blue}" ]]; then
    err "cutover target = '${target}', expected '${expected_blue}'"
    fail=1
  fi

  log "green cluster compatibility (if present)"
  if cluster_exists "${GREEN_CLUSTER}"; then
    local g_phase g_major
    g_phase=$(kctl get cluster "${GREEN_CLUSTER}" -o jsonpath='{.status.phase}' || echo "")
    g_major=$(kctl get cluster "${GREEN_CLUSTER}" -o jsonpath='{.spec.imageCatalogRef.major}' || echo "")
    if [[ "${g_phase}" != "Cluster in healthy state" ]]; then
      err "green cluster phase = '${g_phase}'"
      fail=1
    fi
    if [[ -n "${g_major}" && "${g_major}" != "18" ]]; then
      err "green cluster major = '${g_major}', expected 18"
      fail=1
    fi
  fi

  log "recording installed CRD spec fields for run-time templating"
  {
    echo "=== publication.spec ==="
    kubectl explain publication.spec --api-version=postgresql.cnpg.io/v1 || true
    echo
    echo "=== subscription.spec ==="
    kubectl explain subscription.spec --api-version=postgresql.cnpg.io/v1 || true
  } >"${STATE_DIR_ABS}/cnpg-crd-fields.txt"

  if (( fail > 0 )); then
    die "preflight FAILED (${fail} issue(s)). See messages above."
  fi
  ok "preflight passed"
}

# ----------------------------------------------------------------------------
# Subcommand: prepare-blue
# ----------------------------------------------------------------------------

cmd_prepare_blue() {
  require_tools
  local current_context
  current_context=$(kubectl config current-context)
  [[ "${CONFIRM_CONTEXT}" == "true" ]] \
    || die "kubectl context = ${current_context}. Set CONFIRM_CONTEXT=true once verified."
  ok "context confirmed: ${current_context}"

  if [[ -z "${REPLICA_IDENTITY_FULL_TABLES}" ]]; then
    warn "REPLICA_IDENTITY_FULL_TABLES empty; nothing to prepare"
    return 0
  fi

  cluster_exists "${BLUE_CLUSTER}" || die "blue cluster ${BLUE_CLUSTER} not found in ${NAMESPACE}"

  log "setting REPLICA IDENTITY FULL on configured blue tables"
  local table schema rel
  for table in ${REPLICA_IDENTITY_FULL_TABLES}; do
    [[ "${table}" == *.* ]] || die "table '${table}' must be schema-qualified"
    schema=${table%%.*}
    rel=${table#*.}
    validate_identifier schema "${schema}"
    validate_identifier table "${rel}"
    psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
      "ALTER TABLE ${schema}.${rel} REPLICA IDENTITY FULL;"
  done

  ok "blue replica identity prerequisites applied"
}

# ----------------------------------------------------------------------------
# Subcommand: create-green
# ----------------------------------------------------------------------------

cmd_create_green() {
  require_tools
  if cluster_exists "${GREEN_CLUSTER}"; then
    local major phase
    major=$(kctl get cluster "${GREEN_CLUSTER}" -o jsonpath='{.spec.imageCatalogRef.major}')
    phase=$(kctl get cluster "${GREEN_CLUSTER}" -o jsonpath='{.status.phase}')
    if [[ "${major}" == "18" && "${phase}" == "Cluster in healthy state" ]]; then
      log "green cluster ${GREEN_CLUSTER} already healthy at PG18; re-applying manifest to pick up spec drift"
      kctl apply -f "${MIGRATION_MANIFEST_DIR}/cluster-green.yaml"
    else
      warn "green cluster exists but major=${major}, phase=${phase}; re-applying"
      kctl apply -f "${MIGRATION_MANIFEST_DIR}/cluster-green.yaml"
    fi
  else
    kctl apply -f "${MIGRATION_MANIFEST_DIR}/cluster-green.yaml"
  fi

  log "waiting for green cluster to reach healthy state (timeout 600s)"
  local end=$(( SECONDS + 600 ))
  local phase=""
  while (( SECONDS < end )); do
    phase=$(kctl get cluster "${GREEN_CLUSTER}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "${phase}" == "Cluster in healthy state" ]]; then
      ok "green cluster healthy"
      break
    fi
    sleep 5
  done
  [[ "${phase}" == "Cluster in healthy state" ]] || die "green cluster failed to become healthy"

  log "verifying CNPG-generated app secret ${GREEN_APP_SECRET}"
  local keys
  keys=$(kctl get secret "${GREEN_APP_SECRET}" -o jsonpath='{.data}' 2>/dev/null \
    | jq -r 'keys | join(",")' || echo "")
  [[ -n "${keys}" ]] || die "secret ${GREEN_APP_SECRET} was not generated by CNPG"
  for required in ${REQUIRED_APP_SECRET_KEYS}; do
    [[ ",${keys}," == *",${required},"* ]] \
      || die "${GREEN_APP_SECRET} missing required key '${required}' (have: ${keys})"
  done
  ok "green cluster ready; ${GREEN_APP_SECRET} has expected key shape"
}

# ----------------------------------------------------------------------------
# Subcommand: copy-schema
# ----------------------------------------------------------------------------

cmd_copy_schema() {
  require_tools
  validate_identifier GREEN_USER "${GREEN_USER}"
  cluster_exists "${GREEN_CLUSTER}" || die "green cluster ${GREEN_CLUSTER} not present"

  local schema_file="${STATE_DIR_ABS}/schema.sql"
  local has_tables
  has_tables=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "SELECT count(*) FROM pg_stat_user_tables;" | tr -d '[:space:]')
  if [[ "${has_tables}" -gt 0 && "${FORCE_SCHEMA}" != "true" ]]; then
    warn "green already has ${has_tables} user tables; skipping. Set FORCE_SCHEMA=true to override."
    return 0
  fi

  local blue_pod green_pod
  blue_pod=$(primary_pod "${BLUE_CLUSTER}")
  green_pod=$(primary_pod "${GREEN_CLUSTER}")

  log "dumping schema from blue (${blue_pod})"
  kctl exec -c postgres "${blue_pod}" -- \
    pg_dump --schema-only --no-owner --no-acl --dbname "${BLUE_DATABASE}" >"${schema_file}"
  if [[ "${SCHEMA_REWRITE_UNLOGGED_TABLES}" == "true" ]]; then
    log "rewriting CREATE UNLOGGED TABLE to CREATE TABLE for PG18 schema compatibility"
    sed -i.bak 's/^CREATE UNLOGGED TABLE /CREATE TABLE /' "${schema_file}"
  fi
  log "schema written to ${schema_file} ($(wc -l <"${schema_file}") lines)"

  log "restoring schema into green (${green_pod})"
  {
    printf 'SET ROLE %s;\n' "${GREEN_USER}"
    cat "${schema_file}"
  } | kctl exec -i -c postgres "${green_pod}" -- \
    psql -X -v ON_ERROR_STOP=1 -d "${GREEN_DATABASE}"

  log "verifying restored object ownership"
  local wrong_owner
  wrong_owner=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" "WITH objects AS (
    SELECT c.oid AS object_oid, 0 AS object_subid, 'pg_class'::regclass AS catalog_oid,
           n.nspname AS schema_name, c.relname AS object_name, pg_get_userbyid(c.relowner) AS owner
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','p','S','v','m','f')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    UNION ALL
    SELECT p.oid, 0, 'pg_proc'::regclass,
           n.nspname, p.proname, pg_get_userbyid(p.proowner)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  )
  SELECT schema_name || '.' || object_name || ' owned by ' || owner
  FROM objects
  WHERE owner <> '${GREEN_USER}'
    AND NOT EXISTS (
      SELECT 1
      FROM pg_depend d
      WHERE d.classid = objects.catalog_oid
        AND d.objid = objects.object_oid
        AND d.objsubid = objects.object_subid
        AND d.refclassid = 'pg_extension'::regclass
    )
  ORDER BY 1
  LIMIT 20;")
  if [[ -n "${wrong_owner}" ]]; then
    err "green schema has objects not owned by ${GREEN_USER}:"
    printf '%s\n' "${wrong_owner}" | indent_stderr
    die "schema ownership check failed"
  fi
  ok "schema copied to green and owned by ${GREEN_USER}"
}

# ----------------------------------------------------------------------------
# Subcommand: publication
# ----------------------------------------------------------------------------

cmd_publication() {
  require_tools
  kctl apply -f "${MIGRATION_MANIFEST_DIR}/publication.yaml"
  log "waiting for Publication CR to settle"
  sleep 3
  local exists
  exists=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
    "SELECT 1 FROM pg_publication WHERE pubname = '${PUBLICATION_PG_NAME}';" | tr -d '[:space:]')
  [[ "${exists}" == "1" ]] || die "PostgreSQL publication ${PUBLICATION_PG_NAME} did not materialise"
  ok "publication ${PUBLICATION_PG_NAME} present on blue"
}

# ----------------------------------------------------------------------------
# Subcommand: subscription
# ----------------------------------------------------------------------------

cmd_subscription() {
  require_tools
  kctl apply -f "${MIGRATION_MANIFEST_DIR}/subscription.yaml"
  log "waiting for Subscription CR to start receiving WAL"
  local end=$(( SECONDS + 120 ))
  local lsn=""
  while (( SECONDS < end )); do
    lsn=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
      "SELECT received_lsn FROM pg_stat_subscription WHERE subname = '${SUBSCRIPTION_PG_NAME}';" \
      2>/dev/null | tr -d '[:space:]' || echo "")
    [[ -n "${lsn}" && "${lsn}" != "0/0" ]] && break
    sleep 3
  done
  if [[ -z "${lsn}" || "${lsn}" == "0/0" ]]; then
    warn "subscription not yet streaming. Inspect with: task postgres:monitor"
  else
    ok "subscription streaming. received_lsn=${lsn}"
  fi
}

cmd_subscription_reset() {
  require_tools
  kctl delete --ignore-not-found subscription "${SUBSCRIPTION_NAME}"
  cmd_subscription
}

# ----------------------------------------------------------------------------
# Subcommand: monitor
# ----------------------------------------------------------------------------

cmd_monitor() {
  require_tools
  log "Publication CR status"
  kctl get publication "${PUBLICATION_NAME}" -o yaml 2>/dev/null \
    | yq '.status // {}' || true
  echo

  log "Subscription CR status"
  kctl get subscription "${SUBSCRIPTION_NAME}" -o yaml 2>/dev/null \
    | yq '.status // {}' || true
  echo

  log "pg_stat_subscription (green)"
  psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" "SELECT
    subname, pid, received_lsn, latest_end_lsn, latest_end_time
  FROM pg_stat_subscription;" || true
  echo

  log "pg_subscription_rel state counts (green)"
  psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "SELECT srsubstate, count(*) FROM pg_subscription_rel GROUP BY srsubstate ORDER BY 1;" || true
  echo

  log "replication slots (blue)"
  psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SELECT
    slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn
  FROM pg_replication_slots
  ORDER BY slot_name;" || true
  echo

  local blue_lsn green_lsn
  blue_lsn=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SELECT pg_current_wal_lsn();" | tr -d '[:space:]')
  green_lsn=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "SELECT COALESCE(latest_end_lsn::text, '0/0') FROM pg_stat_subscription WHERE subname='${SUBSCRIPTION_PG_NAME}' LIMIT 1;" \
    | tr -d '[:space:]' || echo "0/0")
  local lag_bytes
  lag_bytes=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
    "SELECT pg_wal_lsn_diff('${blue_lsn}'::pg_lsn, '${green_lsn}'::pg_lsn);" | tr -d '[:space:]')
  log "lag: blue=${blue_lsn}, green=${green_lsn}, delta=${lag_bytes} bytes"
}

table_counts() {
  local cluster=$1 dbname=$2
  local count_sql exclude_filter table schema rel
  exclude_filter=""
  for table in ${ROWCOUNT_EXCLUDE_TABLES}; do
    [[ "${table}" == *.* ]] || die "row-count exclude table '${table}' must be schema-qualified"
    schema=${table%%.*}
    rel=${table#*.}
    validate_identifier schema "${schema}"
    validate_identifier table "${rel}"
    exclude_filter+=" AND NOT (n.nspname = '${schema}' AND c.relname = '${rel}')"
  done

  count_sql=$(psql_as_super "${cluster}" "${dbname}" "SELECT COALESCE(string_agg(
    format('SELECT %L AS rel, count(*)::bigint AS rows FROM %I.%I',
      n.nspname || '.' || c.relname, n.nspname, c.relname),
    ' UNION ALL ' ORDER BY n.nspname || '.' || c.relname), '')
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r','p')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    ${exclude_filter};")
  if [[ -z "${count_sql}" ]]; then
    return 0
  fi
  psql_as_super "${cluster}" "${dbname}" "${count_sql} ORDER BY rel;"
}

# ----------------------------------------------------------------------------
# Subcommand: ready
# ----------------------------------------------------------------------------

cmd_ready() {
  require_tools
  local fail=0

  local target expected_blue
  target=$(repo_cutover_target)
  expected_blue=$(blue_cutover_target)
  [[ "${target}" == "${expected_blue}" ]] \
    || { err "cutover target moved to ${target}, expected blue (${expected_blue})"; fail=1; }

  local server_version_num
  server_version_num=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "SHOW server_version_num;" | tr -d '[:space:]')
  [[ "${server_version_num}" -ge 180000 ]] \
    || { err "green server_version_num=${server_version_num}, need >=180000"; fail=1; }

  local not_ready
  not_ready=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "SELECT count(*) FROM pg_subscription_rel WHERE srsubstate <> 'r';" | tr -d '[:space:]')
  [[ "${not_ready}" == "0" ]] \
    || { err "${not_ready} subscription_rel rows not yet in state 'r'"; fail=1; }

  local blue_lsn green_lsn lag_bytes
  blue_lsn=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SELECT pg_current_wal_lsn();" | tr -d '[:space:]')
  green_lsn=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "SELECT COALESCE(latest_end_lsn::text, '0/0') FROM pg_stat_subscription WHERE subname='${SUBSCRIPTION_PG_NAME}' LIMIT 1;" \
    | tr -d '[:space:]' || echo "0/0")
  lag_bytes=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
    "SELECT pg_wal_lsn_diff('${blue_lsn}'::pg_lsn, '${green_lsn}'::pg_lsn);" | tr -d '[:space:]')
  if (( lag_bytes > READY_LAG_BYTES )); then
    err "replication lag ${lag_bytes} bytes > READY_LAG_BYTES (${READY_LAG_BYTES})"
    fail=1
  fi

  for cluster in "${BLUE_CLUSTER}" "${GREEN_CLUSTER}"; do
    local phase
    phase=$(kctl get cluster "${cluster}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "${phase}" == "Cluster in healthy state" ]] \
      || { err "cluster ${cluster} not healthy (phase='${phase}')"; fail=1; }
  done

  if (( fail > 0 )); then
    die "not ready (${fail} issue(s))"
  fi
  ok "READY: green caught up, app still on blue, both clusters healthy"
}

# ----------------------------------------------------------------------------
# Subcommand: cutover
# ----------------------------------------------------------------------------

cmd_cutover() {
  require_tools
  if [[ -f "${CUTOVER_STATE_FILE}" ]]; then
    local stage
    stage=$(jq -r '.stage // ""' "${CUTOVER_STATE_FILE}")
    if [[ "${stage}" == "awaiting-handoff" ]]; then
      log "resuming cutover after GitOps handoff"
      resume_cutover_after_handoff "${CUTOVER_STATE_FILE}"
      return 0
    fi
  fi

  cmd_ready

  local state_file="${CUTOVER_STATE_FILE}"
  if [[ -f "${state_file}" ]] && [[ "$(jq -r '.stage // ""' "${state_file}")" == "started" ]]; then
    log "using existing replica counts from ${state_file}"
  else
    log "saving current deployment replica counts"
    local replicas_json="{"
    local workload key
    while read -r workload; do
      [[ -n "${workload}" ]] || continue
      key=$(workload_state_key "${workload}")
      local r
      r=$(kctl get "${workload}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      replicas_json+="\"${key}\":${r:-0},"
    done < <(app_workloads)
    replicas_json="${replicas_json%,}}"
    jq -n --argjson r "${replicas_json}" '{stage:"started", replicas:$r}' >"${state_file}"
    log "saved: ${state_file}"
  fi

  log "triggering on-demand backup of blue"
  local backup_name
  backup_name="${BLUE_CLUSTER}-pre-cutover-$(date -u +%Y%m%d%H%M%S)"
  kubectl cnpg backup "${BLUE_CLUSTER}" \
    --namespace "${NAMESPACE}" \
    --backup-name "${backup_name}" \
    --method plugin \
    --plugin-name barman-cloud.cloudnative-pg.io
  log "waiting for backup ${backup_name} to complete (timeout ${BACKUP_WAIT_TIMEOUT}s)"
  local end=$(( SECONDS + BACKUP_WAIT_TIMEOUT ))
  local phase=""
  while (( SECONDS < end )); do
    phase=$(kctl get backup.postgresql.cnpg.io "${backup_name}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "${phase}" == "completed" ]] && break
    [[ "${phase}" == "failed" ]] && die "backup ${backup_name} FAILED"
    sleep 5
  done
  [[ "${phase}" == "completed" ]] || die "backup ${backup_name} did not complete in time (phase=${phase})"
  ok "backup completed: ${backup_name}"

  log "scaling app to 0"
  while read -r workload; do
    [[ -n "${workload}" ]] || continue
    kctl scale "${workload}" --replicas=0
  done < <(app_workloads)
  while read -r workload; do
    [[ -n "${workload}" ]] || continue
    kctl rollout status "${workload}" --timeout=120s
  done < <(app_workloads)

  log "capturing blue WAL LSN"
  local target_lsn
  target_lsn=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "SELECT pg_current_wal_lsn();" | tr -d '[:space:]')
  log "target LSN: ${target_lsn}"

  log "waiting for green to catch up to ${target_lsn}"
  end=$(( SECONDS + CUTOVER_WAIT_TIMEOUT ))
  local diff=999999999
  while (( SECONDS < end )); do
    diff=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" "SELECT
      pg_wal_lsn_diff('${target_lsn}'::pg_lsn,
        COALESCE((SELECT latest_end_lsn FROM pg_stat_subscription WHERE subname='${SUBSCRIPTION_PG_NAME}' LIMIT 1), '0/0'::pg_lsn));" \
      | tr -d '[:space:]')
    diff=${diff:-999999999}
    if [[ "${diff}" -le 0 ]]; then
      ok "green caught up (delta=${diff})"
      break
    fi
    sleep 2
  done
  (( diff <= 0 )) || die "green did not catch up to ${target_lsn} within ${CUTOVER_WAIT_TIMEOUT}s"

  log "disabling subscription on green (keeping the slot for rollback)"
  psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "ALTER SUBSCRIPTION ${SUBSCRIPTION_PG_NAME} DISABLE;" || warn "ALTER SUBSCRIPTION DISABLE failed (might already be disabled)"

  log "synchronising sequences"
  local seq_sql
  seq_sql=$(psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" "WITH seqs AS (
    SELECT ns.nspname AS sschema, s.relname AS sname,
           tns.nspname AS tschema, t.relname AS tname, a.attname AS col
    FROM pg_class s
    JOIN pg_namespace ns ON ns.oid = s.relnamespace
    JOIN pg_depend d ON d.objid = s.oid
    JOIN pg_class t ON t.oid = d.refobjid
    JOIN pg_namespace tns ON tns.oid = t.relnamespace
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
    WHERE s.relkind = 'S'
  )
  SELECT format('SELECT setval(''%I.%I'', GREATEST(1, %s, COALESCE((SELECT MAX(%I) FROM %I.%I),0)), true);',
    sschema, sname,
    COALESCE((SELECT last_value FROM pg_sequences WHERE schemaname=sschema AND sequencename=sname), 0),
    col, tschema, tname)
  FROM seqs;")
  if [[ -n "${seq_sql}" ]]; then
    log "applying $(echo "${seq_sql}" | grep -c setval) setval(...) statements to green"
    echo "BEGIN;" >"${STATE_DIR_ABS}/sequences.sql"
    echo "${seq_sql}" >>"${STATE_DIR_ABS}/sequences.sql"
    echo "COMMIT;" >>"${STATE_DIR_ABS}/sequences.sql"
    psql_as_super_stdin "${GREEN_CLUSTER}" "${GREEN_DATABASE}" <"${STATE_DIR_ABS}/sequences.sql"
    ok "sequences synced"
  else
    log "no owned sequences found"
  fi

  log "row count parity check"
  local diff_rows
  diff_rows=$(table_counts "${BLUE_CLUSTER}" "${BLUE_DATABASE}" | sort)
  local green_rows
  green_rows=$(table_counts "${GREEN_CLUSTER}" "${GREEN_DATABASE}" | sort)
  if ! diff <(echo "${diff_rows}") <(echo "${green_rows}") >"${STATE_DIR_ABS}/rowcount.diff"; then
    err "row counts differ between blue and green. See ${STATE_DIR_ABS}/rowcount.diff"
    err "Aborting cutover. Investigate, fix, retry."
    # Re-enable subscription so it can keep replicating while we sort this out.
    psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
      "ALTER SUBSCRIPTION ${SUBSCRIPTION_PG_NAME} ENABLE;" || true
    # Restore replicas
    local workload key
    while read -r workload; do
      [[ -n "${workload}" ]] || continue
      key=$(workload_state_key "${workload}")
      local r
      r=$(jq -r ".replicas.\"${key}\"" "${state_file}")
      [[ "${r}" == "0" || "${r}" == "null" ]] && r=1
      kctl scale "${workload}" --replicas="${r}"
    done < <(app_workloads)
    die "row-count mismatch"
  fi
  ok "row counts match"
  save_cutover_stage "${state_file}" "awaiting-handoff"

  if [[ "${CUTOVER_TARGET_TYPE}" == "helm-value" || "${CUTOVER_TARGET_TYPE}" == "secret-key" ]]; then
    log "updating repo cutover target in $(repo_cutover_file)"
    set_repo_cutover_target "$(green_cutover_target)"
  fi

  local cutover_file
  cutover_file=$(repo_cutover_file)

  cat <<EOF

${BOLD}===================================================================${RESET}
${BOLD}MANUAL STEP REQUIRED — commit the cutover edit${RESET}
${BOLD}===================================================================${RESET}

In ${cutover_file}, verify the configured cutover target:

  - ${CUTOVER_TARGET_TYPE}: $(blue_cutover_target)
  + ${CUTOVER_TARGET_TYPE}: $(green_cutover_target)

Then:

  git add ${cutover_file}
  git commit -m "feat(${HELMRELEASE}): cut over to ${GREEN_CLUSTER} (PG18)"
  git push
  flux reconcile kustomization ${HELMRELEASE} -n flux-system

Once the cutover edit is reconciled, re-run:

  task postgres:cutover PG_PROFILE=${PG_PROFILE:-<profile>} CONFIRM_CONTEXT=true   # resumes from ${state_file}, restores replicas, runs postcheck + grafana-postcheck

To wake this script without re-running the full task, create the file:

  touch ${STATE_DIR_ABS}/proceed

App deployments are currently scaled to 0; they will scale back up to
their saved replicas after postcheck completes.

EOF

  log "waiting for ${STATE_DIR_ABS}/proceed (timeout ${CUTOVER_WAIT_TIMEOUT}s)"
  end=$(( SECONDS + CUTOVER_WAIT_TIMEOUT ))
  while (( SECONDS < end )); do
    if [[ -f "${STATE_DIR_ABS}/proceed" || "${CUTOVER_PROCEED:-false}" == "true" ]]; then
      break
    fi
    sleep 3
  done
  if [[ ! -f "${STATE_DIR_ABS}/proceed" && "${CUTOVER_PROCEED:-false}" != "true" ]]; then
    die "operator did not signal proceed within ${CUTOVER_WAIT_TIMEOUT}s. App is still scaled to 0. To resume, touch the proceed file and re-run."
  fi
  rm -f "${STATE_DIR_ABS}/proceed"

  log "verifying HelmRelease now points at $(green_cutover_target)"
  local target expected_green
  target=$(repo_cutover_target)
  expected_green=$(green_cutover_target)
  [[ "${target}" == "${expected_green}" ]] \
    || die "cutover target in ${cutover_file:-repo} is '${target}', expected '${expected_green}'. App is still scaled to 0; complete the cutover edit or rollback."

  resume_cutover_after_handoff "${state_file}"
}

# ----------------------------------------------------------------------------
# Subcommand: postcheck
# ----------------------------------------------------------------------------

cmd_postcheck() {
  require_tools
  local fail=0

  log "app workloads rolled out"
  local workload
  while read -r workload; do
    [[ -n "${workload}" ]] || continue
    kctl rollout status "${workload}" --timeout=300s \
      || { err "${workload} did not roll out"; fail=1; }
  done < <(app_workloads)

  log "cutover target points at green"
  local target expected_green
  target=$(live_cutover_target)
  expected_green=$(green_cutover_target)
  if [[ "${target}" != "${expected_green}" ]]; then
    err "live cutover target='${target}', expected '${expected_green}'"
    fail=1
  fi

  if [[ -n "${POSTCHECK_ENV_VAR}" ]]; then
    log "app env ${POSTCHECK_ENV_VAR} points at green"
    for deploy in ${APP_DEPLOYMENTS}; do
      local pod host selector
      selector="${APP_POD_SELECTOR:-app.kubernetes.io/name=${deploy}}"
      pod=$(kctl get pod -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
        || kctl get pod -l "app.kubernetes.io/component=${deploy}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
        || echo "")
      [[ -n "${pod}" ]] || { warn "no pod found for ${deploy}, skipping env check"; continue; }
      host=$(kctl exec "${pod}" -- env 2>/dev/null | awk -F= -v key="${POSTCHECK_ENV_VAR}" '$1 == key {print $2}' || echo "")
      if [[ -z "${host}" ]]; then
        warn "${deploy} pod ${pod} did not expose ${POSTCHECK_ENV_VAR}; relying on live cutover target check"
        continue
      fi
      if [[ "${host}" != "${GREEN_CLUSTER}-rw" && "${host}" != "${GREEN_CLUSTER}-rw."* && "${host}" != "$(green_cutover_target)" ]]; then
        err "${deploy} pod ${pod} ${POSTCHECK_ENV_VAR}='${host}' does not point at green"
        fail=1
      fi
    done
  fi

  log "green DB identity"
  psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "SELECT version(), current_database(), current_user, inet_server_addr();" || fail=1

  if [[ "${REQUIRE_APP_CONNECTIONS}" == "true" ]]; then
    log "active app connections on green > 0"
    local conn
    conn=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
      "SELECT count(*) FROM pg_stat_activity WHERE datname='${GREEN_DATABASE}' AND usename='${GREEN_USER}';" \
      | tr -d '[:space:]')
    if (( conn < 1 )); then
      err "no app connections on green"
      fail=1
    fi
  else
    warn "REQUIRE_APP_CONNECTIONS=false, skipping active app connection check"
  fi

  log "no invalid indexes"
  local invalid
  invalid=$(psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" "SELECT
    n.nspname || '.' || c.relname FROM pg_index ix
    JOIN pg_class c ON c.oid = ix.indexrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT ix.indisvalid;")
  if [[ -n "${invalid}" ]]; then
    err "invalid indexes on green:"
    printf '%s\n' "${invalid}" | indent_stderr
    fail=1
  fi

  if [[ -n "${HEALTH_URL}" ]] && command -v curl >/dev/null 2>&1; then
    log "HTTP smoke: ${HEALTH_URL}"
    if curl -fsS --max-time 10 "${HEALTH_URL}" >/dev/null; then
      ok "health endpoint responded 2xx"
    else
      warn "health endpoint smoke failed (network from caller may be limited; verify manually)"
    fi
  elif [[ -n "${HEALTH_URL}" ]]; then
    warn "curl not available, skipping HTTP smoke"
  else
    warn "HEALTH_URL empty, skipping HTTP smoke"
  fi

  log "recent logs free of common DB failure strings"
  while read -r workload; do
    [[ -n "${workload}" ]] || continue
    local log_key
    log_key=$(workload_state_key "${workload}")
    if kctl logs "${workload}" --since=5m 2>/dev/null \
       | grep -Ei 'ECONNREFUSED|password authentication failed|database .* does not exist|relation .* does not exist|duplicate key' \
       >"${STATE_DIR_ABS}/log-issues-${log_key}.txt"; then
      err "${workload} log issues — see ${STATE_DIR_ABS}/log-issues-${log_key}.txt"
      fail=1
    else
      rm -f "${STATE_DIR_ABS}/log-issues-${log_key}.txt"
    fi
  done < <(app_workloads)

  if (( fail > 0 )); then
    die "postcheck FAILED (${fail} issue(s))"
  fi
  ok "postcheck passed"
}

# ----------------------------------------------------------------------------
# Subcommand: grafana-postcheck
# ----------------------------------------------------------------------------

prom_query() {
  local q=$1
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 5 -G "${PROMETHEUS_URL}/api/v1/query" \
      --data-urlencode "query=${q}" 2>/dev/null \
      | jq -r '.data.result // []'
  else
    echo "[]"
  fi
}

cmd_grafana_postcheck() {
  require_tools
  if [[ "${GRAFANA_MCP_ENABLED}" == "true" ]]; then
    warn "GRAFANA_MCP_ENABLED=true but MCP execution from this script not yet wired."
    warn "Falling back to direct Prometheus HTTP query."
  fi

  local fail=0

  log "green pods up"
  local up
  up=$(prom_query "up{namespace=\"${NAMESPACE}\",pod=~\"${GREEN_CLUSTER}-.*\"}")
  if [[ "${up}" == "[]" ]]; then
    warn "no 'up' series matched for ${GREEN_CLUSTER}; Prometheus may not be reachable from this host"
  else
    local zeros
    zeros=$(echo "${up}" | jq '[.[] | select(.value[1] != "1")] | length')
    if (( zeros > 0 )); then
      err "${zeros} green pods report up != 1"
      fail=1
    fi
  fi

  log "active app connections by cluster"
  prom_query "sum by (pod) (cnpg_pg_stat_activity_count{namespace=\"${NAMESPACE}\",datname=\"${GREEN_DATABASE}\"})" \
    | jq -r '.[] | "  \(.metric.pod) -> \(.value[1])"' || true

  log "container restarts in last 15m"
  local restarts
  restarts=$(prom_query "sum(increase(kube_pod_container_status_restarts_total{namespace=\"${NAMESPACE}\",pod=~\"${PROM_POD_REGEX}\"}[15m]))")
  echo "${restarts}" | jq -r '.[] | "  total=\(.value[1])"' || true

  if (( fail > 0 )); then
    return 1
  fi
  ok "grafana-postcheck completed (informational where Prometheus unreachable)"
}

# ----------------------------------------------------------------------------
# Subcommand: rollback
# ----------------------------------------------------------------------------

cmd_rollback() {
  require_tools
  local target
  target=$(repo_cutover_target)

  if [[ "${target}" == "$(blue_cutover_target)" ]]; then
    log "pre-cutover rollback: app still on blue"
    log "  -- removing migration objects"
    psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
      "DROP SUBSCRIPTION IF EXISTS ${SUBSCRIPTION_PG_NAME};" 2>/dev/null || true
    psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
      "DROP PUBLICATION IF EXISTS ${PUBLICATION_PG_NAME};" 2>/dev/null || true
    kctl delete --ignore-not-found -f "${MIGRATION_MANIFEST_DIR}/subscription.yaml"
    kctl delete --ignore-not-found -f "${MIGRATION_MANIFEST_DIR}/publication.yaml"
    kctl delete --ignore-not-found -f "${MIGRATION_MANIFEST_DIR}/cluster-green.yaml"
    rm -f "${CUTOVER_STATE_FILE}"
    ok "pre-cutover rollback complete"
    return 0
  fi

  log "post-cutover rollback: app currently on green (${target})"
  cat <<EOF

${BOLD}===================================================================${RESET}
${RED}WARNING: any writes accepted on green since cutover are NOT
replicated back to blue. Rollback will lose those writes.${RESET}

Required:
  ACCEPT_DATA_LOSS=true task postgres:rollback

Manual steps to perform from another shell:
  1. git revert <cutover-sha>
  2. git push
  3. flux reconcile helmrelease ${HELMRELEASE} -n ${NAMESPACE}
  4. Wait for both ${APP_DEPLOYMENTS} deployments to roll.

EOF
  [[ "${ACCEPT_DATA_LOSS}" == "true" ]] \
    || die "ACCEPT_DATA_LOSS not set"

  warn "ACCEPT_DATA_LOSS=true acknowledged. Proceeding with kubectl-level scale-and-restart."
  warn "Operator must still revert the HelmRelease commit on the git side."
  ok "rollback prerequisites acknowledged"
}

# ----------------------------------------------------------------------------
# Subcommand: cleanup
# ----------------------------------------------------------------------------

cmd_cleanup() {
  require_tools
  local target
  target=$(repo_cutover_target)
  [[ "${target}" == "$(green_cutover_target)" ]] \
    || die "cutover target is '${target}', expected '$(green_cutover_target)'. Refusing cleanup."

  log "removing CNPG Subscription and Publication"
  psql_as_super "${GREEN_CLUSTER}" "${GREEN_DATABASE}" \
    "DROP SUBSCRIPTION IF EXISTS ${SUBSCRIPTION_PG_NAME};" || true
  psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
    "DROP PUBLICATION IF EXISTS ${PUBLICATION_PG_NAME};" || true
  kctl delete --ignore-not-found subscription "${SUBSCRIPTION_NAME}"
  kctl delete --ignore-not-found publication "${PUBLICATION_NAME}"

  log "dropping any leftover replication slot on blue"
  psql_as_super "${BLUE_CLUSTER}" "${BLUE_DATABASE}" \
    "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '${SUBSCRIPTION_PG_NAME}';" \
    || true

  cat <<EOF

${BOLD}Blue cluster (${BLUE_CLUSTER}) is still present.${RESET}

When you are satisfied that green is healthy and you no longer need blue's
data, delete it manually:

  kubectl -n ${NAMESPACE} delete cluster ${BLUE_CLUSTER}

This script does not delete it automatically.

EOF

  log "clearing runtime artifacts (keeping .gitkeep)"
  find "${STATE_DIR_ABS}" -mindepth 1 -not -name '.gitkeep' -delete || true
  ok "cleanup complete"
}

# ----------------------------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
usage: pg-bluegreen.sh <subcommand>

  discover                   snapshot CNPG/app/db state
  show-active                print which secret the helmrelease points at
  preflight                  validate prerequisites
  blue-connection            print blue cluster URI (for ad-hoc psql)
  green-connection           print green cluster URI
  prepare-blue               apply profile-declared blue DB prerequisites
  create-green               apply green CNPG cluster and wait
  copy-schema                pg_dump --schema-only from blue -> green
  publication                apply CNPG Publication CR
  subscription               apply CNPG Subscription CR
  subscription-reset         delete/recreate CNPG Subscription CR
  monitor                    print pub/sub + replication status
  ready                      exit 0 if green is caught up
  cutover                    perform write-stop window + hand off to operator
  postcheck                  validate post-cutover state
  grafana-postcheck          Prometheus/Loki checks
  rollback                   revert to blue
  cleanup                    drop pub/sub, clear runtime state
EOF
}

main() {
  local cmd=${1:-}
  shift || true
  case "${cmd}" in
    discover)          cmd_discover "$@" ;;
    show-active)       cmd_show_active "$@" ;;
    preflight)         cmd_preflight "$@" ;;
    blue-connection)   cmd_connection "${BLUE_APP_SECRET}" ;;
    green-connection)  cmd_connection "${GREEN_APP_SECRET}" ;;
    prepare-blue)      cmd_prepare_blue "$@" ;;
    create-green)      cmd_create_green "$@" ;;
    copy-schema)       cmd_copy_schema "$@" ;;
    publication)       cmd_publication "$@" ;;
    subscription)      cmd_subscription "$@" ;;
    subscription-reset) cmd_subscription_reset "$@" ;;
    monitor)           cmd_monitor "$@" ;;
    ready)             cmd_ready "$@" ;;
    cutover)           cmd_cutover "$@" ;;
    postcheck)         cmd_postcheck "$@" ;;
    grafana-postcheck) cmd_grafana_postcheck "$@" ;;
    rollback)          cmd_rollback "$@" ;;
    cleanup)           cmd_cleanup "$@" ;;
    -h|--help|"")      usage ;;
    *)                 usage; die "unknown subcommand: ${cmd}" ;;
  esac
}

main "$@"
