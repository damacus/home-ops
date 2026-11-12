# Sleeping applications

KEDA 2.21.0 and HTTP add-on 0.16.0 provide on-demand application startup.
The HTTPRoute sends traffic through the existing interceptor. Its
InterceptorRoute selects the application Service, and a ScaledObject owns the
application's replica count. Authentication filters remain on the HTTPRoute.

Memos, Hubble UI and Longhorn UI run at most one replica and sleep after 30
minutes without traffic. Only the UI deployments sleep: Cilium, Hubble relay
and Longhorn storage components continue running.

Penpot's frontend, backend, exporter and MCP deployments share the frontend's
traffic signal, so they wake and sleep together. The frontend readiness check
uses its proxied backend API. PostgreSQL, shared Redis and asset storage remain
available. Open WebSocket connections keep the application active; after the
last connection closes, the 30-minute cooldown allows background exports to
finish. Avoid shutting down an active export manually.

Cold requests wait up to three minutes for startup, with a four-minute total
request timeout. An open browser tab, external uptime check or API client can
keep an application awake. Kubernetes readiness and liveness probes go directly
to pods and do not trigger HTTP scaling.

Mealie uses a schedule rather than HTTP waking: one replica daily from 08:00
to 23:00 Europe/London, and zero overnight. The timezone follows UK daylight
saving. Requests overnight do not wake it. Scheduled application tasks do not
run while it sleeps. Its PostgreSQL database and data volume remain intact.

## Inspect or wake an application

Use an explicit Kubernetes context:

```fish
kubectl --context ironstone get scaledobject -A
kubectl --context ironstone get interceptorroute -A
kubectl --context ironstone -n home get deployment memos
```

Opening the normal application URL wakes an HTTP-scaled application.
Do not continually request the URL while checking idle shutdown.

For maintenance, pause a ScaledObject at one replica and remove the annotation
afterwards so normal scaling resumes:

```fish
kubectl --context ironstone -n home annotate scaledobject memos autoscaling.keda.sh/paused-replicas=1
kubectl --context ironstone -n home annotate scaledobject memos autoscaling.keda.sh/paused-replicas-
```

The same override can wake Mealie outside its normal hours. Persist desired
behaviour in Git; direct replica changes alone can be overwritten by KEDA.
