#!/usr/bin/env bash
set -euo pipefail

ETCD_VERSION="v3.6.7"
ETCD_URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-arm64.tar.gz"
curl -sL "${ETCD_URL}" | sudo tar -zxv --strip-components=1 -C /usr/local/bin
