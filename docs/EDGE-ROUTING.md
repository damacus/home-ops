# Edge Routing

## Canonical Rules

- Traefik is the default HTTP edge for Kubernetes applications.
- `HTTPRoute` is the preferred route type for new and migrated services.
- `ingress-nginx-internal` remains as a temporary compatibility lane for services that still require classic `Ingress` behavior.
- Do not add a separate `traefik-external` controller or a second Traefik `LoadBalancer`; public and private hostnames share the same Traefik edge and differ by DNS and tunnel exposure.
- `ingress-nginx-external` should not be used for new work.

## Why HTTPRoute Stays The Default

The active WebSocket problems in this repository came from the earlier Cilium Gateway API and Envoy Gateway migrations, not the current Traefik Gateway implementation.

Relevant history:

- `87304b8a` `fix: disable ALPN to force HTTP/1.1 for websocket support`
- `db9cfdad` `fix: nginx ingress for Home Assistant websockets`
- `ff4c275f` `fix cilium websocket appprotocol`
- `ec3c34a1` `fix(envoy): change ALPN order to prefer HTTP/1.1 for WebSocket support`
- `84ed3295` `refactor(cilium): remove Cilium Gateway API`
- `896189c3` `feat(network): add Traefik ingress controller with Gateway API support`
- `6ef18cd0` `feat: migrate all routes from Envoy Gateway to Traefik`

Supporting references:

- [Gateway API backend protocol guide](https://gateway-api.sigs.k8s.io/guides/backend-protocol/)
- [Traefik WebSocket support](https://doc.traefik.io/traefik/master/expose/overview/)
- [Traefik Kubernetes Gateway provider](https://doc.traefik.io/traefik/master/providers/kubernetes-gateway/)
- [RFC 8441](https://www.rfc-editor.org/rfc/rfc8441)

## Current Route Inventory

| Service | Hosts | Type | Parent / Class | WS | UDP | Edge proto | Bucket |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Home Assistant | `hass.ironstone.casa`, `home-assistant.ironstone.casa`, `hass.damacus.io`, `home-assistant.damacus.io` | HTTPRoute | Traefik `traefik-internal` | Yes, active `wss` monitor | mDNS UDP on Service | H1/H2/H3 | Validate only |
| ESPHome | `esphome.ironstone.casa` | Ingress | nginx `internal` | Likely yes | No | H1/H2 | Migrate carefully |
| code-server | `code.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | Likely yes | No | H1/H2/H3 | Validate only |
| Frigate | `frigate.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | Likely yes | Separate RTSP TCP | H1/H2/H3 | Validate only |
| n8n | `n8n.ironstone.casa`, `n8n-webhooks.damacus.io` | HTTPRoute | Traefik `traefik-internal` | No hard WS dependency known | No | H1/H2/H3 | Already good |
| Paperless | `paperless.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | No hard WS dependency known | No | H1/H2/H3 | Already good |
| Mealie | `mealie.damacus.io` | HTTPRoute | Traefik `traefik-internal` | No hard WS dependency known | No | H1/H2/H3 | Already good |
| Med Tracker | `med-tracker.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | No hard WS dependency known | No | H1/H2/H3 | Already good |
| Zitadel | `zitadel.damacus.io` | HTTPRoute | Traefik `traefik-internal` | No | No | H1/H2/H3 edge, h2c backend | Leave as-is |
| Grafana | `grafana.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | Possible live UI traffic, not a blocker | No | H1/H2/H3 | Already good |
| Victoria Metrics | `metrics.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | No | No | H1/H2/H3 | Already good |
| Gatus | `gatus.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | No | No | H1/H2/H3 | Already good |
| Longhorn | `longhorn.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | No hard WS dependency known | No | H1/H2/H3 | Already good |
| MinIO | `minio.ironstone.casa`, `s3.ironstone.casa`, `ironbuckets.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | No | No | H1/H2/H3 | Already good |
| Echo Server | `echo-server.ironstone.casa`, `echo-server.damacus.io` | HTTPRoute | Traefik `traefik-internal` | No | No | H1/H2/H3 | Canary route |
| Flux webhook | `flux-webhook.damacus.io` | HTTPRoute | Traefik `traefik-internal` | No | No | H1/H2/H3 | Already good |
| Hubble UI | `hubble.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | No hard WS dependency known | No | H1/H2/H3 | Already good |
| 1Password Connect | `onepassword-connect.ironstone.casa` | HTTPRoute | Traefik `traefik-internal` | No | No | H1/H2/H3 | Migration target |
| PiKVM | `pikvm.ironstone.casa` | HTTPRoute | stale `internal` / `kube-system` | Possible WS / console streaming | No | Unknown | Not minimal |
Direct `LoadBalancer` services outside the HTTP edge: `matter`, `mosquitto`, `whisper`, and `wakeword`.

Direct appliance DNS aliases outside the HTTP edge: `drive.ironstone.casa` and `unas.ironstone.casa` on UNAS-Pro `192.168.1.243`, plus `unifi.ironstone.casa` on Ironstone `192.168.1.254`.

## Validation Workflow

- `task kubernetes:edge-smoke` validates the baseline Traefik edge.
- `task kubernetes:edge-smoke-esphome` adds the ESPHome Traefik canary hostname and can enforce a known websocket path via `esphome_ws_path=...`.
- HTTP/3 checks are informational; lack of local client support should not block a rollout.
- Home Assistant keeps the existing `wss://home-assistant.ironstone.casa/api/websocket` regression check as the canary for long-lived WebSocket behavior.
