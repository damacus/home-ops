#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(git rev-parse --show-toplevel)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Exercise the queries and pending periods from the actual Grafana provisioning.
yq '.data."unifi.yaml" | from_yaml | {"groups": [.groups[] | {"name": .name, "rules": [.rules[] | {"alert": .uid, "expr": (.data[0].model.expr + " > " + (.data[1].model.conditions[0].evaluator.params[0] | tostring)), "for": .for, "labels": .labels}]}]}' \
  "$repo_dir/kubernetes/apps/monitoring/unpoller/app/grafana-alerts.yaml" > "$test_dir/unifi-rules.yaml"
cp "$repo_dir/tests/monitoring/unifi-alerts.test.yaml" "$test_dir/"
promtool test rules "$test_dir/unifi-alerts.test.yaml"

# Preserve the real routing tree but remove delivery endpoints from the fixture.
yq '.spec.target.template.data."alertmanager.yaml" | from_yaml | .receivers = [{"name":"heartbeat"},{"name":"null"},{"name":"oncall"},{"name":"oncall-critical"}]' \
  "$repo_dir/kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml" > "$test_dir/alertmanager.yaml"
amtool config routes test --config.file="$test_dir/alertmanager.yaml" \
  --verify.receivers=null alertname=UniFiChannelHigh alertgroup=unifi-radio severity=warning
amtool config routes test --config.file="$test_dir/alertmanager.yaml" \
  --verify.receivers=oncall-critical alertname=UniFiChannelSaturated alertgroup=unifi-radio severity=critical
amtool config routes test --config.file="$test_dir/alertmanager.yaml" \
  --verify.receivers=oncall-critical alertname=OtherCritical severity=critical
