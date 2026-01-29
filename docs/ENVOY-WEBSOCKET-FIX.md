# Envoy Gateway WebSocket Configuration

## Problem

Applications using WebSocket connections (e.g., Home Assistant) fail to load when accessed through Envoy Gateway. The UI shows a loading screen indefinitely.

## Root Cause

Envoy Gateway negotiates HTTP/2 by default via ALPN. WebSocket upgrade requires HTTP/1.1 with a `101 Switching Protocols` response. Without explicit configuration, the protocol mismatch causes WebSocket connections to fail.

### Diagnosis

```bash
# HTTP/2 (default) - hangs, no upgrade possible
curl -v https://home-assistant.ironstone.casa/api/websocket
# Output: ALPN: server accepted h2
# Result: Connection hangs

# HTTP/1.1 (forced) - works correctly
curl -v --http1.1 https://home-assistant.ironstone.casa/api/websocket
# Output: HTTP/1.1 101 Switching Protocols
# Result: WebSocket upgrade successful
```

## Solution

Add `httpUpgrade` configuration to the `BackendTrafficPolicy` in `/kubernetes/apps/network/envoy-gateway/config/envoy.yaml`:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: envoy
spec:
  # ... other config ...
  httpUpgrade:
    - type: websocket
```

## Affected Applications

Any application that uses WebSocket connections:

- **Home Assistant** - Real-time UI updates
- **Code Server** - Terminal and editor sync
- **n8n** - Workflow execution feedback
- **Grafana** - Live dashboard updates

## Verification

After applying the fix:

1. Check Home Assistant loads fully (not stuck on loading screen)
2. Open browser DevTools → Network → WS tab
3. Verify WebSocket connection shows `101 Switching Protocols`

## References

- [Envoy Gateway BackendTrafficPolicy API](https://gateway.envoyproxy.io/docs/api/extension_types/#backendtrafficpolicyspec)
- [ProtocolUpgradeConfig](https://gateway.envoyproxy.io/docs/api/extension_types/#protocolupgradeconfig)
- PR #2922 - Implementation fix
