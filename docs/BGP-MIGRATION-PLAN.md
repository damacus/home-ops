# Cilium service BGP rollout

## Design

Cilium allocates opt-in LoadBalancer services from 192.168.3.2–192.168.3.254.
UniFi learns their individual /32 routes via authenticated BGP from the nodes.
The nodes retain their DHCP addresses on 192.168.1.0/24. UniFi is ASN 65000;
Cilium is ASN 65020. Dynamic peers accommodate node address changes.

Services labelled `network.ironstone.casa/advertisement: bgp` use the BGP pool
and advertisements. Unlabelled services retain the L2 pool and policy for compatibility and
rollback. This PR opts all eight existing LoadBalancer services into BGP;
their address changes are listed below. kube-vip remains in ARP mode at
192.168.1.220 and does not participate in these BGP sessions.

The Kubernetes VLAN remains VLAN 2, with gateway 192.168.3.1/24. DHCP,
auto-scale, IPv6 prefix delegation and router advertisements were disabled
and read back on 2026-09-14. Other network objects were verified unchanged.
Keeping the connected /24 does not prevent more-specific BGP /32 routes from
winning; the gateway address is excluded from allocation and import.

## Router and authentication

`scripts/unifi/bgp.cfg` is a template, not an upload-ready credential file.
Save the rendered upload as a `.conf` text file; UniFi rejects `.cfg`.
Render `BGP_PASSWORD` using the `password` key of the dedicated
`kube-system/cilium-bgp-auth` Secret. Never commit or print the rendered file.
Keep a copy in a protected password store for cluster disaster recovery.

The router accepts authenticated peers from 192.168.1.0/24, with a maximum
of ten peers, and imports only service /32 routes. It exports no routes to
the nodes. There is no redistribution of WAN, connected or default routes.
The completed initial test used a single service. The application cutover
below moves all eight existing LoadBalancer services. Three equal-cost paths are permitted when all nodes advertise a route.

Use UniFi Settings → Routing → BGP → existing `k3s` configuration to replace
the uploaded file. Preserve Override WAN Monitors and SD-WAN settings.
Do not change FRR with SSH `write memory`: the controller owns this config.
Download the existing file before replacing it. The pre-change config peered
only with 192.168.1.200. Keep its backup outside Git for rollback.

## Validation and rollout

1. Run `python3 -m unittest discover -s tests -p test_bgp_migration.py`.
2. Validate `kubectl --context ironstone apply --server-side --dry-run=server
   --force-conflicts --field-manager=bgp-validation -k
   kubernetes/apps/kube-system/cilium/config`. Conflict resolution here is
   dry-run only, not permission to overwrite Flux field ownership live.
3. Parse the rendered router file using FRR. The isolated local FRR 10.4.1
   parser accepts the template, but the local Docker kernel lacks TCP MD5;
   authentication must be checked on the actual gateway.
4. Upload the matching authenticated router configuration. Publish the
   Cilium configuration through the normal reviewed Flux workflow before
   considering it durable. Avoid applying it only live: Flux would revert it.
5. Confirm all three peers are Established and initially advertise no routes.
6. Apply `docs/examples/bgp-test-service.yaml`. It adds a separate, temporary
   service to the existing Traefik pods, with no DNS or application changes.
7. Confirm 192.168.3.10 allocation, the /32 route and next hops on UniFi, and
   successful HTTPS access from a management-subnet client using an existing
   Traefik hostname and `curl --resolve hostname:443:192.168.3.10`.
8. Delete only `network/bgp-test` after testing; confirm withdrawal of its
   /32 route and continued access through the original Traefik address.

For rollback, remove the test service, restore the Cilium manifests from the
previous Git revision and upload the backed-up UniFi configuration. Keep the
new unused Secret until rollback is confirmed; never delete shared secrets
as part of a broad cleanup. No node, kube-vip or application restart is needed.

## Single-PR application cutover

This PR includes both the BGP configuration and all eight Service migrations.
There are no temporary old-address aliases. Retain the final octet:

| Service | Previous IP | BGP IP |
| --- | --- | --- |
| ESPHome | 192.168.1.227 | 192.168.3.227 |
| Mosquitto | 192.168.1.229 | 192.168.3.229 |
| Piper | 192.168.1.231 | 192.168.3.231 |
| Whisper | 192.168.1.232 | 192.168.3.232 |
| Matter | 192.168.1.234 | 192.168.3.234 |
| OpenWakeWord | 192.168.1.235 | 192.168.3.235 |
| Forgejo SSH | 192.168.1.236 | 192.168.3.236 |
| Traefik | 192.168.1.238 | 192.168.3.238 |

All requests use `lbipam.cilium.io/ips`; old `loadBalancerIP` fields and
`io.cilium/lb-ipam-ips` annotations are removed. Service names, port mappings
and pod selectors are unchanged. The pinned Helm charts were rendered before
and after the changes to verify this for all eight Services.

Before deployment, reconfigure Home Assistant's Matter integration from
`ws://192.168.1.234:5580/ws` to
`ws://matter-server.home-automation.svc.cluster.local:5580/ws` and verify its
connection. The internal name resolves from the running Home Assistant pod.
Do this through the integration's supported configuration flow, not by editing
its storage file while Home Assistant is running.

The owner accepts leaving the Piper and Whisper integrations pointing at their
old addresses; voice repair is outside this cutover. Home Assistant's MQTT
integration already uses `mosquitto.home-automation.svc.cluster.local`.
Its ESPHome integrations point at physical device addresses, not this service.
Clients outside Home Assistant may still contain hard-coded old addresses and
have not been exhaustively inventoried.

One PR does not mean an atomic deployment: Flux reconciles the HelmReleases
independently. Before merging, confirm the three BGP sessions and the Matter
connection above. After merging, refresh the Flux source, resume/reconcile
`cilium-config` against the merge revision, and reconcile the eight releases.
Verify each new Service IP and /32 route. Check DNS has moved for
`traefik-int.ironstone.casa`, Gateway-derived records and
`ssh.forgejo.ironstone.casa`, then check HTTPS, Git SSH, MQTT and Matter.
Old DNS caches and active connections can cause an interruption during cutover.
Piper/Whisper application health is explicitly not an acceptance gate.

Rollback the eight HelmRelease Service changes to their previous IP requests
and remove the BGP label. Leave the working BGP infrastructure and L2 pool in
place; the old addresses then use L2 again. Verify DNS returns to the previous
addresses and clients reconnect. Full infrastructure rollback is separate.

## Verified rollout on 2026-09-14

The VLAN settings, dedicated authentication Secret, UniFi configuration and
Cilium configuration are live. All three peers reached Established.
UniFi installed 192.168.3.10/32 with three equal-cost next hops:
192.168.1.27, 192.168.1.186 and 192.168.1.233. HTTPS to this address passed
certificate verification and returned Traefik's default 404 response.

The temporary Service was removed after the test. Subsequent connections to
192.168.3.10 timed out. All eight existing LoadBalancer addresses stayed
unchanged; all three nodes and kube-vip pods remained healthy with no kube-vip
restarts. The initial four regression tests, YAML lint and server-side dry-runs passed.
The expanded five-test suite and all eight pinned chart renders also pass;
the eight-service production cutover has not been performed.

Only `flux-system/cilium-config` is temporarily suspended to prevent the old
Git configuration from overwriting the verified live settings. After merging
this change, refresh the `home-kubernetes` GitRepository to that revision,
resume `cilium-config`, reconcile it and recheck all three BGP sessions.
Do not resume against the old revision. The Cilium workload itself is running.

Sources: [Cilium BGP configuration](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/)
and [UniFi BGP](https://help.ui.com/hc/en-us/articles/16271338193559-UniFi-Border-Gateway-Protocol-BGP).
