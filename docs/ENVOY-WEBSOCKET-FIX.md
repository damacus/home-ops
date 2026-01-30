# Envoy Gateway WebSocket Configuration

## Problem

Applications using WebSocket connections (e.g., Home Assistant) experience:

1. Slow page loads that get progressively worse over time
2. WebSocket connections failing intermittently
3. Static file requests timing out while WebSocket connections work

Restarting the application temporarily fixes the issue, but it returns.

## Root Cause

**Connection Multiplexing Issue**: When Envoy uses HTTP/2 to communicate with backends, multiple requests share a single connection. Long-lived WebSocket connections can block other requests on the same connection, causing static file requests to hang.

Additionally, Envoy Gateway's `ClientTrafficPolicy` advertises ALPN protocols in order `[h2, http/1.1]` by default. Browsers negotiate HTTP/2 via ALPN, but WebSocket upgrade requires HTTP/1.1 with a `101 Switching Protocols` response.

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

### 3. Per-Service BackendTrafficPolicy (Recommended for WebSocket apps)

For applications with mixed HTTP/WebSocket traffic like Home Assistant, create a dedicated `BackendTrafficPolicy`:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: home-assistant
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: home-assistant-internal
  # Force HTTP/1.1 to backend - prevents HTTP/2 multiplexing issues
  useClientProtocol: true
  # WebSocket upgrade support
  httpUpgrade:
    - type: websocket
  # Connection settings to prevent exhaustion
  circuitBreaker:
    maxConnections: 1024
    maxPendingRequests: 1024
    maxParallelRequests: 1024
  # TCP keepalive to detect dead connections
  tcpKeepalive:
    probes: 3
    idleTime: 60s
    interval: 10s
  # Timeout settings - 0s means no timeout for long-lived connections
  timeout:
    http:
      requestTimeout: 0s
      connectionIdleTimeout: 3600s
```

Key settings:

- **`useClientProtocol: true`**: Forces Envoy to use the same protocol the client used (HTTP/1.1), preventing HTTP/2 multiplexing issues with backends that don't support it
- **`connectionIdleTimeout`**: Closes idle connections after 1 hour to prevent connection exhaustion
- **`tcpKeepalive`**: Detects and closes dead connections
- **`circuitBreaker`**: Prevents connection pool exhaustion

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
