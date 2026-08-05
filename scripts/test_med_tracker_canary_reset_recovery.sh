#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
helmrelease="$root_dir/kubernetes/apps/home/med-tracker-canary/app/helmrelease.yaml"
reset_script="$root_dir/kubernetes/apps/home/med-tracker-canary/app/reset-script.yaml"

test "$(yq -r '.spec.values.controllers.reset.containers.app.env.DEMO_RESET_EXPECTED_APPLICATION_HOST' "$helmrelease")" = "med-tracker-canary.damacus.io"
test "$(yq -r '.spec.values.controllers.reset.containers.app.env.DEMO_RESET_EXPECTED_DATABASE_HOST' "$helmrelease")" = "med-tracker-canary-rw.home.svc.cluster.local"
test "$(yq -r '.spec.values.controllers.reset.containers.app.env.DEMO_RESET_EXPECTED_STORAGE_SERVICE' "$helmrelease")" = "persistent"
test "$(yq -r '.spec.values.controllers.reset.containers.app.env.DEMO_RESET_EXPECTED_STORAGE_ROOT' "$helmrelease")" = "/app/storage"
test "$(yq -r '.spec.values.controllers.reset.containers.app.env.DEMO_RESET_EXPECTED_DATABASE_ROLE' "$helmrelease")" = "med_tracker_owner"
test "$(yq -e '[.spec.values.controllers.reset.containers.app.env | keys[] | select(test("^DEMO_RESET_EXPECTED_(S3_ENDPOINT|S3_BUCKET)$"))] | length == 0' "$helmrelease")" = "true"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

yq -r '.data."canary-reset"' "$reset_script" > "$tmp_dir/canary-reset"
mkdir -p "$tmp_dir/bin"

cat > "$tmp_dir/bin/cat" <<'EOF'
#!/bin/sh
printf '%s\n' test-token
EOF

cat > "$tmp_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu

request=GET
data=
url=
while test "$#" -gt 0; do
  case "$1" in
    --request)
      request="$2"
      shift 2
      ;;
    --data)
      data="$2"
      shift 2
      ;;
    --cacert|--header)
      shift 2
      ;;
    --fail|--silent|--show-error)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if test "$request" = PATCH; then
  printf '%s %s %s\n' "$request" "$url" "$data" >> "$RESET_TEST_LOG"
  if test "${RESET_TEST_FAIL_WORKER_SHUTDOWN:-false}" = true && \
    test "$url" = "https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale" && \
    test "$data" = '{"spec":{"replicas":0}}'; then
    exit 10
  fi
  if test "${RESET_TEST_FAIL_WEB_RESTORE:-false}" = true && \
    test "$url" = "https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale" && \
    test "$data" = '{"spec":{"replicas":1}}'; then
    exit 9
  fi
  exit 0
fi

case "$url" in
  *'/pods?'*) printf '%s\n' '{"items":[]}' ;;
  *)
    if grep -Fq "PATCH ${url}/scale {\"spec\":{\"replicas\":1}}" "$RESET_TEST_LOG"; then
      printf '%s\n' '{"spec":{"replicas":1},"status":{"availableReplicas":1}}'
    else
      printf '%s\n' '{"spec":{"replicas":0},"status":{"replicas":0}}'
    fi
    ;;
esac
EOF

cat > "$tmp_dir/bin/rails" <<'EOF'
#!/bin/sh
set -eu

if test "${RESET_TEST_RAILS_STATUS:-42}" -eq 0; then
  test "$(sed -n '1p' "$RESET_TEST_LOG")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale {"spec":{"replicas":0}}'
  test "$(sed -n '2p' "$RESET_TEST_LOG")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale {"spec":{"replicas":0}}'
fi

exit "${RESET_TEST_RAILS_STATUS:-42}"
EOF

chmod +x "$tmp_dir/bin/cat" "$tmp_dir/bin/curl" "$tmp_dir/bin/rails"

set +e
(
  cd "$tmp_dir"
  KUBERNETES_SERVICE_HOST=test KUBERNETES_SERVICE_PORT_HTTPS=443 PATH="$tmp_dir/bin:$PATH" RESET_TEST_LOG="$tmp_dir/requests" /bin/sh "$tmp_dir/canary-reset"
)
status=$?
set -e

test "$status" -eq 42
test "$(sed -n '1p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale {"spec":{"replicas":0}}'
test "$(sed -n '2p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale {"spec":{"replicas":0}}'
test "$(sed -n '3p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale {"spec":{"replicas":1}}'
test "$(sed -n '4p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale {"spec":{"replicas":1}}'
test "$(wc -l < "$tmp_dir/requests" | tr -d ' ')" -eq 4

: > "$tmp_dir/requests"
set +e
(
  cd "$tmp_dir"
  KUBERNETES_SERVICE_HOST=test KUBERNETES_SERVICE_PORT_HTTPS=443 PATH="$tmp_dir/bin:$PATH" RESET_TEST_FAIL_WORKER_SHUTDOWN=true RESET_TEST_LOG="$tmp_dir/requests" /bin/sh "$tmp_dir/canary-reset"
)
status=$?
set -e

test "$status" -eq 10
test "$(sed -n '1p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale {"spec":{"replicas":0}}'
test "$(sed -n '2p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale {"spec":{"replicas":0}}'
test "$(sed -n '3p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale {"spec":{"replicas":1}}'
test "$(sed -n '4p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale {"spec":{"replicas":1}}'
test "$(wc -l < "$tmp_dir/requests" | tr -d ' ')" -eq 4

: > "$tmp_dir/requests"
set +e
(
  cd "$tmp_dir"
  KUBERNETES_SERVICE_HOST=test KUBERNETES_SERVICE_PORT_HTTPS=443 PATH="$tmp_dir/bin:$PATH" RESET_TEST_FAIL_WEB_RESTORE=true RESET_TEST_LOG="$tmp_dir/requests" /bin/sh "$tmp_dir/canary-reset"
)
status=$?
set -e

test "$status" -eq 42
test "$(sed -n '3p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale {"spec":{"replicas":1}}'
test "$(sed -n '4p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale {"spec":{"replicas":1}}'
test "$(wc -l < "$tmp_dir/requests" | tr -d ' ')" -eq 4

: > "$tmp_dir/requests"
set +e
(
  cd "$tmp_dir"
  KUBERNETES_SERVICE_HOST=test KUBERNETES_SERVICE_PORT_HTTPS=443 PATH="$tmp_dir/bin:$PATH" RESET_TEST_LOG="$tmp_dir/requests" RESET_TEST_RAILS_STATUS=0 /bin/sh "$tmp_dir/canary-reset"
)
status=$?
set -e

test "$status" -eq 0
test "$(sed -n '1p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale {"spec":{"replicas":0}}'
test "$(sed -n '2p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale {"spec":{"replicas":0}}'
test "$(sed -n '3p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary/scale {"spec":{"replicas":1}}'
test "$(sed -n '4p' "$tmp_dir/requests")" = 'PATCH https://test:443/apis/apps/v1/namespaces/home/deployments/med-tracker-canary-worker/scale {"spec":{"replicas":1}}'
test "$(wc -l < "$tmp_dir/requests" | tr -d ' ')" -eq 4
