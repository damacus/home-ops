# Frigate access verification

Before treating an access change as complete, verify these cases in an isolated
environment or after an approved GitOps rollout. A render or policy scan alone
does not demonstrate working authentication or network enforcement.

| Caller | Expected behaviour |
| --- | --- |
| Browser without a Zitadel session, through Traefik HTTPS | Redirects to Zitadel; Frigate API and media are not returned |
| Browser with a valid proxy session | UI opens without a Frigate password; all admitted users have admin access; live view and WebSocket event updates work |
| Browser supplying forged identity headers without a proxy session | Redirects to Zitadel; supplied headers do not grant access |
| Authentication proxy unavailable | Frigate access fails closed |
| Traefik pod | Port 8971 works; direct access to ports 5000 and 8554 is denied |
| Home Assistant | Existing internal service URL works on port 5000; live events, alerts and camera access continue |
| Unrelated ordinary cluster pod | Internal ports 5000 and 8554 are denied |
| LAN client | Any reachable direct unauthenticated endpoint is denied |

Home Assistant uses host networking. Cluster nodes are deliberately trusted for
ports 5000 and 8554, so other host-network processes on those nodes share that
access. Verify enforcement with both an ordinary pod and the actual Home
Assistant caller; neither represents the other.

Record the tested image, rendered route and policy, callers and outcomes. Keep
unverified cases explicit. If login or Home Assistant access regresses, revert
through Git. Do not claim the security boundary is proven merely because Flux
and pods report Ready.

Frigate's route and disabled local login are managed together by the Frigate
Flux Kustomization. The route uses the shared oauth2-proxy-forward-auth
middleware, as ESPHome does. Port 8971 stays restricted
to Traefik; do not expose it directly now that the upstream proxy owns login.
The proxy supplies the verified email header, and Frigate gives every admitted
user the admin role. Home Assistant retains its existing internal access.

## Verification recorded on 9 October 2026

Frigate image: `0.18.0-rk@sha256:06f72cee07ddcdba52c7dc8c4ce5d954e51cbc49b655bfdd31bcf0892bdad2eb`.
Traefik image: `docker.io/traefik:v3.7.14`.
The live route was staged with the shared middleware before disabling local
login, keeping authentication enforced throughout the rollout.

| Check | Observed result |
| --- | --- |
| Anonymous HTTPS `/api/config` request | HTTP 302 to Zitadel's authorization endpoint |
| Same request with forged email, remote-user and remote-role headers | HTTP 302 to Zitadel; no Frigate configuration returned |
| Traefik pod requesting internal port 5000 | Timed out after four seconds |
| Actual Home Assistant pod requesting internal port 5000 | HTTP 200 |
| Deployed Frigate configuration models | Accept disabled local authentication, email header mapping and default admin role |
| YAML schemas and rendered chart | Passed; route retains port 8971 and adds shared ForwardAuth |

Traefik strips each configured `authResponseHeaders` entry before copying the
authentication server's value, even when the response omits that header. The
shared middleware lists `X-Auth-Request-Email`, so the caller's supplied email
cannot survive a missing proxy response header. See the
[deployed version's implementation](https://github.com/traefik/traefik/blob/v3.7.14/pkg/middlewares/auth/forward.go#L322-L328).

Still unverified: signed-in browser identity and admin access, WebSocket and
live-media behaviour, Home Assistant camera/events/RTSP, direct access from an
ordinary unrelated pod and LAN client, and failure injection of the auth proxy.
The disabled local-login setting had not yet rolled out when these results
were recorded. Repeat the relevant checks after Flux applies it.
