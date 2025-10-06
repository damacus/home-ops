#!/bin/bash
# Description: Automates the compaction and defragmentation of the k3s embedded etcd database.
# This helps maintain performance and reduce disk space usage on your etcd nodes (your Pi 5s).

# --- 1. Define Environment Variables for K3s Etcd Access ---
# These variables point etcdctl to the local k3s etcd instance using the required TLS certificates.
export ETCDCTL_ENDPOINTS='https://127.0.0.1:2379'
export ETCDCTL_CACERT='/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt'
export ETCDCTL_CERT='/var/lib/rancher/k3s/server/tls/etcd/server-client.crt'
export ETCDCTL_KEY='/var/lib/rancher/k3s/server/tls/etcd/server-client.key'
export ETCDCTL_API=3

# A helper function to execute etcdctl commands and handle errors
run_etcdctl() {
    echo "--> Running: etcdctl $@"
    etcdctl "$@"
    if [ $? -ne 0 ]; then
        echo "ERROR: etcdctl command failed on $1. Maintenance halted." >&2
        exit 1
    fi
}

echo "--- K3s Embedded Etcd Maintenance Started ---"

# --- 2. Initial Health Check & Status ---
echo -e "\n--- Initial Status Check ---"
run_etcdctl endpoint health --cluster --write-out=table
run_etcdctl endpoint status --cluster --write-out=table

# --- 3. Compaction: Find the latest revision and compact ---
echo -e "\n--- Compaction Phase ---"

# Fetch the current revision from the endpoint status output (as seen in your history)
# We grep for 'Revision', cut by the colon separator, and clean up whitespace.
echo "Fetching latest revision for compaction..."
REV=$(run_etcdctl endpoint status --write-out fields | grep -i '"Revision"' | cut -d: -f2 | tr -d '[:space:]')

if [[ -z "$REV" ]]; then
    echo "ERROR: Failed to retrieve a valid etcd revision. Cannot compact." >&2
    exit 1
fi

echo "  -> Found latest revision: $REV"
echo "  -> Compacting etcd database up to revision $REV..."
run_etcdctl compact "$REV"
echo "  -> Compaction complete."

# --- 4. Defragmentation ---
echo -e "\n--- Defragmentation Phase ---"
echo "Defragmenting all etcd members in the cluster to reclaim disk space..."
# This command defrags the entire cluster, one member at a time.
run_etcdctl defrag --cluster
echo "  -> Defragmentation complete."

# --- 5. Final Health and Performance Check ---
echo -e "\n--- Final Checks ---"
echo "Checking final cluster health and status..."
run_etcdctl endpoint health --cluster --write-out=table
run_etcdctl endpoint status --cluster --write-out=table

echo -e "\nRunning etcd performance check (latency/throughput)..."
run_etcdctl check perf

echo -e "\n--- Etcd Maintenance finished successfully. ---"
