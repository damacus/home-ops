#!/bin/bash
set -euo pipefail
systemctl stop k3s
rm -rf /var/lib/rancher/k3s/server/db/etcd
systemctl start k3s
