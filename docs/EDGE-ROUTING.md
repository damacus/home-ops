# Edge routing

Use this to work out whether a failure belongs to DNS, Traefik or the service
behind it. The [migration history](history/edge-routing-migrations.md) explains
the earlier WebSocket failures and controller changes; the
[BGP rollout notes](BGP-MIGRATION-PLAN.md) explain service addressing.

## How traffic reaches an app

Traefik is the default HTTP edge. Applications use Gateway API `HTTPRoute`
resources, usually attached to `traefik-internal`. Public and private hostnames
share this edge; DNS and tunnel exposure determine who can reach each one.
Don't create a second Traefik LoadBalancer to separate them.

Cilium handles pod networking and LoadBalancer service addresses. Direct TCP,
UDP and appliance traffic can bypass the HTTP edge entirely.

## Find the current route

Read the application's HTTPRoute and Service in Git, then inspect the actual
objects with an explicit context:

```console
kubectl --context ironstone get gateways,httproutes -A
kubectl --context ironstone -n network get pods,services
```

For the affected route, inspect its parent acceptance, backend references,
service ports and endpoints. Compare the requested hostname with its DNS answer,
TLS certificate and any public tunnel mapping.

The [chart catalogue](helm-charts.md) links to each deployment's configuration.
RustFS now owns the production S3 endpoint; the former MinIO inventory belongs
to history. Treat manifests as the address inventory rather than maintaining
another hostname/status table here.

## Check the edge

- `task kubernetes:edge-smoke` checks the baseline Traefik edge.
- `task kubernetes:edge-smoke-esphome` adds the ESPHome canary and accepts `esphome_ws_path=...`.
- Home Assistant's `/api/websocket` check protects long-lived WebSocket behaviour.
- HTTP/3 checks are informational when the local client lacks support.

A healthy HTTP response doesn't establish authentication, WebSocket operation
or network-policy enforcement. Check the path actually affected by the fault.

## Before changing controllers

Earlier Cilium/Envoy migrations caused WebSocket faults. That history isn't a
reason to replace a working Traefik HTTPRoute with nginx Ingress.
Check backend protocol and the specific WebSocket path first.

Useful references: [Gateway API backend protocols](https://gateway-api.sigs.k8s.io/guides/backend-protocol/)
and [Traefik's Kubernetes Gateway provider](https://doc.traefik.io/traefik/master/providers/kubernetes-gateway/).
