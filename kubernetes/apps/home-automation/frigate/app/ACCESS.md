# Frigate access verification

Before treating an access change as complete, verify these cases in an isolated
environment or after an approved GitOps rollout. A render or policy scan alone
does not demonstrate working authentication or network enforcement.

| Caller | Expected behaviour |
| --- | --- |
| Browser without a Frigate session, through Traefik HTTPS | Protected API denies access; login page may remain public |
| Browser with a valid Frigate session | UI, live view and event updates work, including WebSocket connections |
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
