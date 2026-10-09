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

Frigate's route, dedicated ForwardAuth middleware and disabled local login are
managed together by the Frigate Flux Kustomization. Port 8971 stays restricted
to Traefik; do not expose it directly now that the upstream proxy owns login.
The proxy supplies the verified email header, and Frigate gives every admitted
user the admin role. Home Assistant retains its existing internal access.
