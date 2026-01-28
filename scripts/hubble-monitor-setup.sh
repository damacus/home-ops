#!/usr/bin/env bash
set -euo pipefail

# Hubble Network Monitoring for Home Assistant WebSocket Debugging
# Usage: ./scripts/hubble-monitor-setup.sh [action] [options]
#
# Actions:
#   info      - Show pod and gateway info (default)
#   http      - Monitor HTTP traffic to Home Assistant (10 events)
#   to        - Monitor all traffic TO Home Assistant (10 events)
#   from      - Monitor all traffic FROM Home Assistant (10 events)
#   dropped   - Monitor dropped packets (10 events)
#   port      - Monitor traffic on port 8123 (10 events)
#   status    - Monitor specific HTTP status code (e.g., 400)
#
# Options:
#   --follow  - Follow mode (continuous, requires Ctrl+C)
#   --count N - Number of events to capture (default: 10)

ACTION="${1:-info}"
FOLLOW=""
COUNT=10

# Parse options
shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --follow|-f)
            FOLLOW="--follow"
            shift
            ;;
        --count|-n)
            COUNT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Get pod info
get_pod_info() {
    HASS_POD=$(kubectl get pod -n home-automation -l app.kubernetes.io/name=home-assistant -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "not-found")
    HASS_IP=$(kubectl get pod -n home-automation -l app.kubernetes.io/name=home-assistant -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "unknown")
    HASS_NODE=$(kubectl get pod -n home-automation -l app.kubernetes.io/name=home-assistant -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "unknown")
    GATEWAY_IP=$(kubectl get svc -n kube-system cilium-gateway-internal -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "unknown")
}

get_pod_info

case "$ACTION" in
    info)
        echo "========================================"
        echo "Hubble Network Monitoring Info"
        echo "========================================"
        echo ""
        echo "Home Assistant Pod: $HASS_POD"
        echo "Pod IP: $HASS_IP"
        echo "Running on Node: $HASS_NODE"
        echo "Internal Gateway IP: $GATEWAY_IP"
        echo ""
        echo "Available actions:"
        echo "  ./scripts/hubble-monitor-setup.sh http      # HTTP traffic"
        echo "  ./scripts/hubble-monitor-setup.sh to        # Traffic TO pod"
        echo "  ./scripts/hubble-monitor-setup.sh from      # Traffic FROM pod"
        echo "  ./scripts/hubble-monitor-setup.sh dropped   # Dropped packets"
        echo "  ./scripts/hubble-monitor-setup.sh port      # Port 8123 traffic"
        echo "  ./scripts/hubble-monitor-setup.sh status 400 # HTTP 400 errors"
        echo ""
        echo "Add --follow for continuous monitoring"
        ;;
    http)
        echo "Monitoring HTTP traffic to Home Assistant (${COUNT} events)..."
        if [[ -n "$FOLLOW" ]]; then
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --pod "home-automation/${HASS_POD}" \
                --protocol http \
                --follow
        else
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --pod "home-automation/${HASS_POD}" \
                --protocol http \
                --last "$COUNT"
        fi
        ;;
    to)
        echo "Monitoring traffic TO Home Assistant (${COUNT} events)..."
        if [[ -n "$FOLLOW" ]]; then
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --to-pod "home-automation/${HASS_POD}" \
                --follow
        else
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --to-pod "home-automation/${HASS_POD}" \
                --last "$COUNT"
        fi
        ;;
    from)
        echo "Monitoring traffic FROM Home Assistant (${COUNT} events)..."
        if [[ -n "$FOLLOW" ]]; then
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --from-pod "home-automation/${HASS_POD}" \
                --follow
        else
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --from-pod "home-automation/${HASS_POD}" \
                --last "$COUNT"
        fi
        ;;
    dropped)
        echo "Monitoring DROPPED packets (${COUNT} events)..."
        if [[ -n "$FOLLOW" ]]; then
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --verdict DROPPED \
                --follow
        else
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --verdict DROPPED \
                --last "$COUNT"
        fi
        ;;
    port)
        echo "Monitoring port 8123 traffic (${COUNT} events)..."
        if [[ -n "$FOLLOW" ]]; then
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --port 8123 \
                --follow
        else
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --port 8123 \
                --last "$COUNT"
        fi
        ;;
    status)
        STATUS_CODE="${2:-400}"
        echo "Monitoring HTTP ${STATUS_CODE} responses (${COUNT} events)..."
        if [[ -n "$FOLLOW" ]]; then
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --http-status "$STATUS_CODE" \
                --follow
        else
            kubectl exec -n kube-system ds/cilium -- hubble observe \
                --http-status "$STATUS_CODE" \
                --last "$COUNT"
        fi
        ;;
    *)
        echo "Unknown action: $ACTION"
        echo "Run './scripts/hubble-monitor-setup.sh info' for help"
        exit 1
        ;;
esac
