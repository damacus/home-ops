# Grafana OnCall Plugin Fix

## Problem

Grafana OnCall plugin showed error: "Plugin is not connected - jsonData.stackId is not set"

## Root Cause

The Grafana HelmRelease was missing the plugin provisioning configuration required for the OnCall plugin to connect properly.

## Solution Applied

Added `pluginManagement` section to the Grafana HelmRelease with the following configuration:

```yaml
pluginManagement:
  plugins.yaml:
    apiVersion: 1
    apps:
      - type: grafana-oncall-app
        org_id: 1
        enabled: true
        jsonData:
          stackId: 1
          orgId: 1
          onCallApiUrl: $__env{GF_PLUGIN_GRAFANA_ONCALL_APP_ONCALL_API_URL}
```

## Key Points

- The `stackId` field is required for the plugin to initialize properly
- The `onCallApiUrl` references the existing environment variable from the external secret
- This configuration is provisioned automatically when Grafana starts
- The setup uses Grafana Cloud OnCall (URL: <https://oncall-prod-eu-west-2.grafana.net/oncall>)

## Files Modified

- `kubernetes/apps/monitoring/grafana/app/helmrelease.yaml`

## Reference

Solution based on: <https://community.grafana.com/t/grafana-oncall-plugin-provisioning/86657/2>

## Next Steps

1. Commit the changes
2. Create PR and merge
3. Wait for Flux to reconcile
4. Verify the plugin connects successfully in Grafana UI

## Status

✅ Configuration added
⏳ Awaiting deployment and verification
