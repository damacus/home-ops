#!/usr/bin/env bash
set -euo pipefail

# Hubble Multi-Terminal Monitoring Setup for Home Assistant WebSocket Debugging
#
# This script provides commands to run in separate terminals to monitor
# websocket traffic between the Gateway and Home Assistant

echo "========================================"
echo "Hubble WebSocket Monitoring Setup"
echo "========================================"
echo ""

# Get pod info
HASS_POD=$(kubectl get pod -n home-automation -l app.kubernetes.io/name=home-assistant -o jsonpath='{.items[0].metadata.name}')
HASS_IP=$(kubectl get pod -n home-automation -l app.kubernetes.io/name=home-assistant -o jsonpath='{.items[0].status.podIP}')
HASS_NODE=$(kubectl get pod -n home-automation -l app.kubernetes.io/name=home-assistant -o jsonpath='{.items[0].spec.nodeName}')

echo "Home Assistant Pod: $HASS_POD"
echo "Pod IP: $HASS_IP"
echo "Running on Node: $HASS_NODE"
echo ""

# Get Gateway info
GATEWAY_IP=$(kubectl get svc -n kube-system cilium-gateway-internal -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Internal Gateway IP: $GATEWAY_IP"
echo ""

echo "========================================"
echo "Terminal Setup Instructions"
echo "========================================"
echo ""

echo "📊 TERMINAL 1 - HTTP Traffic to Home Assistant Pod:"
echo "---------------------------------------------------"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe \\"
echo "  --pod home-automation/$HASS_POD \\"
echo "  --protocol http \\"
echo "  --follow"
echo ""

echo "📊 TERMINAL 2 - All Traffic FROM Home Assistant:"
echo "---------------------------------------------------"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe \\"
echo "  --from-pod home-automation/$HASS_POD \\"
echo "  --follow"
echo ""

echo "📊 TERMINAL 3 - All Traffic TO Home Assistant:"
echo "---------------------------------------------------"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe \\"
echo "  --to-pod home-automation/$HASS_POD \\"
echo "  --follow"
echo ""

echo "📊 TERMINAL 4 - Gateway Envoy Traffic (HTTP only):"
echo "---------------------------------------------------"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe \\"
echo "  --from-ip $GATEWAY_IP \\"
echo "  --protocol http \\"
echo "  --follow"
echo ""

echo "📊 TERMINAL 5 - Specific IP Traffic (replace with your client IP):"
echo "---------------------------------------------------"
echo "# Find your IP from Home Assistant logs first:"
echo "kubectl logs -n home-automation $HASS_POD --tail=10 | grep 'from'"
echo ""
echo "# Then monitor traffic from that IP:"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe \\"
echo "  --ip YOUR.CLIENT.IP.HERE \\"
echo "  --follow"
echo ""

echo "========================================"
echo "Testing Commands"
echo "========================================"
echo ""

echo "🧪 Test WebSocket Connection:"
echo "---------------------------------------------------"
echo "./scripts/test-hass-websocket.sh"
echo ""

echo "🧪 Test via Browser:"
echo "---------------------------------------------------"
echo "1. Open: https://home-assistant.ironstone.casa"
echo "2. Open Browser DevTools (F12) → Network tab"
echo "3. Filter by 'WS' (WebSocket)"
echo "4. Look for /api/websocket connection"
echo "5. Check Status: should be '101 Switching Protocols' (HTTP/1.1)"
echo ""

echo "🧪 Quick HTTP Version Check:"
echo "---------------------------------------------------"
echo "curl -I https://home-assistant.ironstone.casa 2>&1 | grep -i 'http/'"
echo ""

echo "========================================"
echo "What to Look For"
echo "========================================"
echo ""
echo "✅ GOOD - HTTP/1.1 with WebSocket upgrade:"
echo "   - HTTP/1.1 101 Switching Protocols"
echo "   - Connection: Upgrade"
echo "   - Upgrade: websocket"
echo ""
echo "❌ BAD - HTTP/2 blocking WebSocket:"
echo "   - HTTP/2 400"
echo "   - No WebSocket UPGRADE hdr"
echo ""

echo "========================================"
echo "Useful Hubble Filters"
echo "========================================"
echo ""
echo "# Filter by verdict (dropped packets):"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --follow"
echo ""
echo "# Filter by port (Home Assistant):"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe --port 8123 --follow"
echo ""
echo "# Filter by HTTP status code:"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe --http-status 400 --follow"
echo ""
echo "# Show only forwarded traffic:"
echo "kubectl exec -n kube-system ds/cilium -- hubble observe --verdict FORWARDED --follow"
echo ""
