#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(git rev-parse --show-toplevel)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
yq '.spec | .groups |= map(select(.name == "oom"))' \
  "$repo_dir/kubernetes/apps/monitoring/victoria-metrics/app/prometheusrule.yaml" > "$test_dir/oom-rules.yaml"
cp "$repo_dir/tests/monitoring/oom-alert.test.yaml" "$test_dir/"
promtool test rules "$test_dir/oom-alert.test.yaml"
