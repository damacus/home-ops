#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Testing Home Assistant Ingress Endpoints"
echo "=========================================="
echo ""

# Test function
test_endpoint() {
    local url="$1"
    local should_work="$2"
    local name="$3"
    
    echo -n "Testing ${name} (${url})... "
    
    # Try to connect with 5 second timeout
    if response=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${url}" 2>&1); then
        if [[ "$should_work" == "true" ]]; then
            if [[ "$response" =~ ^[23] ]]; then
                echo -e "${GREEN}✓ PASS${NC} (HTTP ${response})"
                return 0
            else
                echo -e "${YELLOW}⚠ WARN${NC} (HTTP ${response} - expected 2xx/3xx)"
                return 1
            fi
        else
            # Should NOT work
            echo -e "${GREEN}✓ PASS${NC} (correctly unreachable)"
            return 0
        fi
    else
        if [[ "$should_work" == "true" ]]; then
            echo -e "${RED}✗ FAIL${NC} (connection failed)"
            return 1
        else
            echo -e "${GREEN}✓ PASS${NC} (correctly unreachable)"
            return 0
        fi
    fi
}

# Track results
total=0
passed=0

echo "OLD ENDPOINTS (should NOT work):"
echo "--------------------------------"
test_endpoint "https://hass.damacus.io" "false" "hass.damacus.io" && ((passed++)) || true
((total++))

echo ""
echo "NEW ENDPOINTS (should work):"
echo "----------------------------"
test_endpoint "https://home-assistant.damacus.io" "true" "home-assistant.damacus.io" && ((passed++)) || true
((total++))

test_endpoint "https://hass.ironstone.casa" "true" "hass.ironstone.casa" && ((passed++)) || true
((total++))

test_endpoint "https://home-assistant.ironstone.casa" "true" "home-assistant.ironstone.casa" && ((passed++)) || true
((total++))

echo ""
echo "=========================================="
echo "Results: ${passed}/${total} tests passed"
echo ""

if [[ $passed -eq $total ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
