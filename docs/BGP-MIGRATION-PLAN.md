# BGP Migration Plan: kube-vip + Cilium

## Goal

Migrate from ARP-based kube-vip to BGP mode so that:
1. **No UniFi config changes needed when adding/removing nodes** (dynamic peering)
2. **Works with DHCP node IPs** (nodes don't need static IPs)
3. **Faster failover** (BGP withdrawal vs ARP cache timeout)
4. **Single VIP advertised via BGP** (192.168.1.220)

---

## Current State

### UniFi Router BGP Config (`scripts/unifi/bgp.cfg`)
```
router bgp 65000
  neighbor 192.168.1.220 peer-group home-kubernetes  # ← Problem: static IP
```

### kube-vip (`kubernetes/apps/kube-system/kube-vip/app/daemonset.yaml`)
- Mode: **ARP** (`vip_arp: "true"`)
- VIP: `192.168.1.220`
- Leader election via Kubernetes lease

### Cilium BGP (`kubernetes/apps/kube-system/cilium/config/bgp.yaml`)
- Already configured for service LoadBalancer IPs
- Peers with UniFi at `192.168.1.254` (AS 65000)
- Local ASN: 65020
- LB Pool: `192.168.3.0/24`

---

## Problem with Current UniFi Config

The UniFi config has:
```
neighbor 192.168.1.220 peer-group home-kubernetes
```

This peers with the **VIP**, not the nodes. Since nodes have DHCP IPs, you can't list them statically.

---

## Solution: BGP Dynamic Neighbors (listen range)

UniFi/FRR supports **dynamic BGP neighbors** using `bgp listen range`. This allows any IP in a CIDR to establish a BGP session without being explicitly configured.

### New UniFi BGP Config

```
router bgp 65000
  bgp router-id 192.168.1.254
  no bgp ebgp-requires-policy

  neighbor home-kubernetes peer-group
  neighbor home-kubernetes remote-as 65020
  neighbor home-kubernetes activate
  neighbor home-kubernetes capability extended-nexthop
  neighbor home-kubernetes soft-reconfiguration inbound

  # Dynamic neighbors - any IP in 192.168.1.0/24 can peer
  bgp listen range 192.168.1.0/24 peer-group home-kubernetes

  address-family ipv4 unicast
    neighbor home-kubernetes next-hop-self
  exit-address-family
```

**Key change**: `bgp listen range 192.168.1.0/24 peer-group home-kubernetes`

This means:
- Any node with a DHCP IP in `192.168.1.0/24` can establish BGP
- No config changes when nodes are added/removed
- No static IP requirements

---

## Implementation Steps

### Phase 1: Verify Cilium BGP is Working

```bash
# Check Cilium BGP status on each node
kubectl exec -n kube-system cilium-<pod> -- cilium-dbg bgp peers

# Verify routes are being advertised
kubectl exec -n kube-system cilium-<pod> -- cilium-dbg bgp routes advertised ipv4 unicast
```

Expected: Cilium should already be peering with 192.168.1.254 for service LB IPs.

### Phase 2: Update UniFi BGP Config

1. SSH to UniFi router
2. Enter FRR shell: `vtysh`
3. Apply new config:

```
configure terminal
router bgp 65000
  no neighbor 192.168.1.220 peer-group home-kubernetes
  bgp listen range 192.168.1.0/24 peer-group home-kubernetes
  bgp listen limit 10
end
write memory
```

4. Verify peers:
```
show bgp summary
show bgp neighbors
```

### Phase 3: Enable kube-vip BGP Mode

Update `kubernetes/apps/kube-system/kube-vip/app/daemonset.yaml`:

```yaml
env:
  - name: address
    value: "192.168.1.220"
  # Disable ARP mode
  - name: vip_arp
    value: "false"
  # Enable BGP mode
  - name: bgp_enable
    value: "true"
  - name: bgp_routerid
    valueFrom:
      fieldRef:
        fieldPath: status.podIP  # Use node IP as router ID
  - name: bgp_as
    value: "65020"  # Same AS as Cilium
  - name: bgp_peeraddress
    value: "192.168.1.254"
  - name: bgp_peeras
    value: "65000"
  - name: bgp_peers
    value: "192.168.1.254:65000::false"  # peer:AS:password:multihop
  # Keep other settings
  - name: port
    value: "6443"
  - name: cp_enable
    value: "true"
  - name: cp_namespace
    value: kube-system
  - name: vip_leaderelection
    value: "true"
  - name: vip_leasename
    value: plndr-cp-lock
```

### Phase 4: Test Failover

1. Identify current kube-vip leader:
   ```bash
   kubectl get lease -n kube-system plndr-cp-lock -o yaml
   ```

2. Delete the leader pod:
   ```bash
   kubectl delete pod -n kube-system kube-vip-<leader-pod>
   ```

3. Watch BGP route withdrawal/advertisement:
   ```bash
   # On UniFi
   watch -n1 'vtysh -c "show bgp ipv4 unicast 192.168.1.220"'
   ```

4. Verify API server remains accessible:
   ```bash
   kubectl get nodes
   ```

### Phase 5: Verify No Static IP Dependency

1. Reboot a node (let it get new DHCP IP if lease expires)
2. Verify BGP session re-establishes
3. Verify VIP failover still works

---

## Rollback Plan

If BGP mode fails:

1. Revert kube-vip to ARP mode:
   ```yaml
   - name: vip_arp
     value: "true"
   - name: bgp_enable
     value: "false"
   ```

2. Revert UniFi config:
   ```
   configure terminal
   router bgp 65000
     no bgp listen range 192.168.1.0/24 peer-group home-kubernetes
     neighbor 192.168.1.220 peer-group home-kubernetes
   end
   write memory
   ```

---

## Architecture After Migration

```
┌─────────────────────────────────────────────────────────────┐
│                    UniFi Router (AS 65000)                  │
│                      192.168.1.254                          │
│                                                             │
│  bgp listen range 192.168.1.0/24 peer-group home-kubernetes │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ eBGP (AS 65000 ↔ AS 65020)
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│  node-0b06a7  │     │  node-0b06df  │     │  node-0b0715  │
│ 192.168.1.233 │     │ 192.168.1.27  │     │ 192.168.1.186 │
│   (DHCP)      │     │   (DHCP)      │     │   (DHCP)      │
│               │     │               │     │               │
│ ┌───────────┐ │     │ ┌───────────┐ │     │ ┌───────────┐ │
│ │ kube-vip  │ │     │ │ kube-vip  │ │     │ │ kube-vip  │ │
│ │  (BGP)    │ │     │ │  (BGP)    │ │     │ │  (BGP)    │ │
│ └───────────┘ │     │ └───────────┘ │     │ └───────────┘ │
│ ┌───────────┐ │     │ ┌───────────┐ │     │ ┌───────────┐ │
│ │  Cilium   │ │     │ │  Cilium   │ │     │ │  Cilium   │ │
│ │  (BGP)    │ │     │ │  (BGP)    │ │     │ │  (BGP)    │ │
│ └───────────┘ │     │ └───────────┘ │     │ └───────────┘ │
└───────────────┘     └───────────────┘     └───────────────┘

Advertised Routes:
- 192.168.1.220/32 (Control Plane VIP) - only from leader
- 192.168.3.x/32 (Service LB IPs) - from all nodes via Cilium
```

---

## Considerations

### ASN Sharing
Both kube-vip and Cilium will use AS 65020. This is fine - they're both on the same nodes and advertising different prefixes.

### BGP Session Limits
`bgp listen limit 10` caps dynamic peers. Adjust if you add more nodes.

### Security
Dynamic BGP neighbors accept connections from any IP in the range. Your network should be trusted. For additional security, consider:
- MD5 authentication (add password to peer-group)
- Prefix filtering on UniFi side

### Monitoring
Add BGP session monitoring:
```bash
# Prometheus metrics from kube-vip
curl http://<node-ip>:2112/metrics | grep bgp
```

---

## Files to Modify

1. **`scripts/unifi/bgp.cfg`** - Update with dynamic neighbor config
2. **`kubernetes/apps/kube-system/kube-vip/app/daemonset.yaml`** - Switch to BGP mode

---

## Estimated Time

- Phase 1 (Verify): 5 minutes
- Phase 2 (UniFi): 10 minutes
- Phase 3 (kube-vip): 15 minutes
- Phase 4 (Test): 15 minutes
- Phase 5 (Verify DHCP): 10 minutes

**Total: ~1 hour** (with buffer for troubleshooting)

---

## References

- [kube-vip BGP documentation](https://kube-vip.io/docs/usage/bgp/)
- [Cilium BGP Control Plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/)
- [FRR Dynamic Neighbors](https://docs.frrouting.org/en/latest/bgp.html#dynamic-neighbors)
