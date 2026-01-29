# Envoy Gateway WebSocket Configuration

## Problem

Applications using WebSocket connections (e.g., Home Assistant) fail to load when accessed through Envoy Gateway. The UI shows a loading screen indefinitely.

## Root Cause

Envoy Gateway's `ClientTrafficPolicy` advertises ALPN protocols in order `[h2, http/1.1]` by default. Browsers negotiate HTTP/2 via ALPN, but WebSocket upgrade requires HTTP/1.1 with a `101 Switching Protocols` response. HTTP/2 WebSocket requires RFC 8441 Extended CONNECT, which is not widely supported.

### Diagnosis

```bash
# HTTP/2 (default ALPN) - fails, no upgrade possible
curl -v https://home-assistant.ironstone.casa/api/websocket
# Output: ALPN: server accepted h2
# Result: HTTP/2 400 Bad Request

# HTTP/1.1 (forced) - works correctly
curl -v --http1.1 https://home-assistant.ironstone.casa/api/websocket
# Output: ALPN: server accepted http/1.1
# Output: HTTP/1.1 101 Switching Protocols
# Result: WebSocket upgrade successful
```

## Solution

### 1. Change ALPN Order (Required)

Update `ClientTrafficPolicy` to prefer HTTP/1.1:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: envoy
spec:
  tls:
    alpnProtocols:
      - http/1.1  # First for WebSocket support
      - h2        # Fallback for other traffic
```

### 2. Enable httpUpgrade in BackendTrafficPolicy (Optional)

WebSocket is enabled by default, but can be explicitly configured:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: envoy
spec:
  httpUpgrade:
    - type: websocket
```

### 3. Backend CRD with appProtocols (Optional)

For explicit WebSocket protocol declaration per-service:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: home-assistant
spec:
  appProtocols:
    - gateway.envoyproxy.io/ws   # WebSocket over HTTP
    - gateway.envoyproxy.io/wss  # WebSocket over HTTPS
  endpoints:
    - fqdn:
        hostname: home-assistant.home-automation.svc.cluster.local
        port: 8123
```

Reference the Backend in HTTPRoute:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  rules:
    - backendRefs:
        - group: gateway.envoyproxy.io
          kind: Backend
          name: home-assistant
```

## Affected Applications

Any application that uses WebSocket connections:

- **Home Assistant** - Real-time UI updates
- **Code Server** - Terminal and editor sync
- **n8n** - Workflow execution feedback
- **Grafana** - Live dashboard updates

## Verification

After applying the fix:

```bash
curl -v https://home-assistant.ironstone.casa/api/websocket 2>&1 | grep -E "(ALPN|HTTP)"
# Expected output:
# ALPN: server accepted http/1.1
# HTTP/1.1 101 Switching Protocols
```

Or in browser:

1. Open DevTools → Network → WS tab
2. Verify WebSocket connection shows `101 Switching Protocols`

## References

- [Envoy Gateway BackendTrafficPolicy API](https://gateway.envoyproxy.io/latest/api/extension_types/#backendtrafficpolicyspec)
- [ProtocolUpgradeConfig](https://gateway.envoyproxy.io/latest/api/extension_types/#protocolupgradeconfig)
- [Backend CRD appProtocols](https://gateway.envoyproxy.io/latest/api/extension_types/#appprotocoltype)
- [ClientTrafficPolicy TLS Settings](https://gateway.envoyproxy.io/latest/api/extension_types/#clienttlssettings)
- PR #2922 - httpUpgrade fix
- PR #2923 - Backend CRD + HTTPRoute
- PR #2924 - ALPN order fix
