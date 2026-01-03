#!/bin/bash
# Inject node-ip into k3s config if not already set
set -euo pipefail

CONFIG_FILE="/etc/rancher/k3s/config.yaml"

# Get node IP from routing table
NODE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)

# Fallback to first IP from hostname
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi

# Only add if we have an IP and config exists and node-ip not already set
if [ -n "$NODE_IP" ] && [ -f "$CONFIG_FILE" ]; then
    if ! grep -qE '^\s*node-ip:' "$CONFIG_FILE"; then
        echo "" >> "$CONFIG_FILE"
        echo "node-ip: $NODE_IP" >> "$CONFIG_FILE"
        echo "Added node-ip: $NODE_IP to $CONFIG_FILE"
    else
        echo "node-ip already configured in $CONFIG_FILE"
    fi
else
    echo "Skipping node-ip injection (IP=$NODE_IP, config exists=$(test -f "$CONFIG_FILE" && echo yes || echo no))"
fi
