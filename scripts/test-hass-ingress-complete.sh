#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "========================================"
echo "Home Assistant Ingress Validation"
echo "========================================"
echo ""

# Test external endpoints
echo -e "${BLUE}Testing External Endpoints:${NC}"
echo "----------------------------"

echo -n "1. hass.damacus.io (should be DEAD): "
if curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://hass.damacus.io" 2>&1 | grep -q "000"; then
    echo -e "${GREEN}✓ PASS${NC} (unreachable)"
else
    echo -e "${RED}✗ FAIL${NC} (still reachable)"
fi

echo -n "2. home-assistant.damacus.io (should work): "
code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://home-assistant.damacus.io" 2>&1 || echo "000")
if [[ "$code" =~ ^[23] ]]; then
    echo -e "${GREEN}✓ PASS${NC} (HTTP ${code})"
else
    echo -e "${RED}✗ FAIL${NC} (HTTP ${code})"
fi

echo ""
echo -e "${BLUE}Testing Internal Endpoints:${NC}"
echo "----------------------------"

echo -n "3. hass.ironstone.casa (should work): "
if host hass.ironstone.casa >/dev/null 2>&1; then
    code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://hass.ironstone.casa" 2>&1 || echo "000")
    if [[ "$code" =~ ^[23] ]]; then
        echo -e "${GREEN}✓ PASS${NC} (HTTP ${code})"
    else
        echo -e "${YELLOW}⚠ WARN${NC} (HTTP ${code} - DNS resolves but service unavailable)"
    fi
else
    echo -e "${YELLOW}⚠ WARN${NC} (DNS not resolving yet)"
fi

echo -n "4. home-assistant.ironstone.casa (should work): "
if host home-assistant.ironstone.casa >/dev/null 2>&1; then
    code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://home-assistant.ironstone.casa" 2>&1 || echo "000")
    if [[ "$code" =~ ^[23] ]]; then
        echo -e "${GREEN}✓ PASS${NC} (HTTP ${code})"
    else
        echo -e "${YELLOW}⚠ WARN${NC} (HTTP ${code} - DNS resolves but service unavailable)"
    fi
else
    echo -e "${YELLOW}⚠ WARN${NC} (DNS not resolving yet)"
fi

echo ""
echo -e "${BLUE}Testing Internal Networking (kubectl port-forward):${NC}"
echo "---------------------------------------------------"

# Start port-forward in background
kubectl port-forward -n home-automation svc/home-assistant 18123:8123 > /tmp/pf-test.log 2>&1 &
PF_PID=$!
sleep 3

echo -n "5. Internal service connectivity: "
if code=$(curl -sS -o /dev/null -w "%{http_code}" http://localhost:18123/api/ 2>&1); then
    if [[ "$code" == "401" ]] || [[ "$code" =~ ^[23] ]]; then
        echo -e "${GREEN}✓ PASS${NC} (HTTP ${code} - service responding)"
    else
        echo -e "${RED}✗ FAIL${NC} (HTTP ${code})"
    fi
else
    echo -e "${RED}✗ FAIL${NC} (connection failed)"
fi

# Cleanup
kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true

echo ""
echo -e "${BLUE}Gateway API Status:${NC}"
echo "-------------------"
kubectl get httproute -n home-automation -o custom-columns=NAME:.metadata.name,HOSTNAMES:.spec.hostnames,STATUS:.status.parents[0].conditions[0].status 2>/dev/null || echo "Unable to fetch HTTPRoute status"

echo ""
echo "========================================"
echo "Test Complete"
echo "========================================"
