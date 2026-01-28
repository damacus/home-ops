#!/usr/bin/env bash
set -euo pipefail

# Home Assistant WebSocket Connection Test
# Usage: ./scripts/test-hass-websocket.sh [hostname]
# Default: home-assistant.ironstone.casa

HOSTNAME="${1:-home-assistant.ironstone.casa}"
RESULTS=""
EXIT_CODE=0

add_result() {
    RESULTS="${RESULTS}${1}\n"
}

echo "Testing Home Assistant WebSocket connection to ${HOSTNAME}..."
echo ""

# Test 1: WebSocket upgrade headers
echo "1. Testing WebSocket upgrade headers:"
WS_RESPONSE=$(curl -s -i -N --http1.1 -H "Connection: Upgrade" \
     -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     "https://${HOSTNAME}/api/websocket" 2>&1 | head -20)
echo "$WS_RESPONSE"

if echo "$WS_RESPONSE" | grep -q "101 Switching Protocols"; then
    add_result "✅ WebSocket upgrade: SUCCESS (HTTP/1.1 101 Switching Protocols)"
elif echo "$WS_RESPONSE" | grep -q "HTTP/2 400"; then
    add_result "❌ WebSocket upgrade: FAILED (HTTP/2 400 - needs HTTP/1.1)"
    EXIT_CODE=1
else
    add_result "⚠️ WebSocket upgrade: UNKNOWN response"
    EXIT_CODE=1
fi

echo ""

# Test 2: HTTP protocol version
echo "2. Testing HTTP protocol version:"
HTTP_RESPONSE=$(curl -s -I --http2 "https://${HOSTNAME}" 2>&1 | head -5)
echo "$HTTP_RESPONSE"

if echo "$HTTP_RESPONSE" | grep -q "HTTP/2"; then
    add_result "📊 HTTP Protocol: HTTP/2 (may break websockets)"
elif echo "$HTTP_RESPONSE" | grep -q "HTTP/1.1"; then
    add_result "📊 HTTP Protocol: HTTP/1.1 (websocket compatible)"
fi

echo ""

# Test 3: Response headers
echo "3. Checking response headers:"
HEADERS=$(curl -s -I "https://${HOSTNAME}" 2>&1 | grep -i "x-forwarded\|connection\|upgrade\|server" || true)
echo "$HEADERS"

if echo "$HEADERS" | grep -qi "envoy"; then
    add_result "🔧 Server: Envoy (Cilium Gateway)"
elif echo "$HEADERS" | grep -qi "nginx"; then
    add_result "🔧 Server: nginx"
fi

echo ""
echo "========================================"
echo "SUMMARY"
echo "========================================"
echo -e "$RESULTS"

exit $EXIT_CODE
