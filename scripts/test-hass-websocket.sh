#!/usr/bin/env bash
set -euo pipefail

echo "Testing Home Assistant WebSocket connection..."
echo ""

# Test websocket upgrade
echo "1. Testing WebSocket upgrade headers:"
curl -i -N -H "Connection: Upgrade" \
     -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://home-assistant.ironstone.casa/api/websocket 2>&1 | head -20

echo ""
echo "2. Testing HTTP/2 support:"
curl -I --http2 https://home-assistant.ironstone.casa 2>&1 | grep -i "http\|upgrade"

echo ""
echo "3. Checking response headers:"
curl -I https://home-assistant.ironstone.casa 2>&1 | grep -i "x-forwarded\|connection\|upgrade"
