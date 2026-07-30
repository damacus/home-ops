## MedTracker canary trace demo

- Started at: `2026-07-30T15:38:49Z`
- Completed within the 15-minute acceptance window
- MedTracker source commit: `1c23f5184e318f2606dd0817df0f2601eada3814`
- Published image index: `sha256:f33f8220160d9db9eec8b647e4e7b7d62e581e606e39989aa6d6f2290be617e9`
- Deployed app and migration image IDs matched the published image index
- Production remained configured with `OTEL_TRACES_EXPORTER=none`

### Safe canary

- Application event: `0ddbeb97-a939-4f9c-9b44-d856ed2d6747`
- Workflow: `cc82d038-6c21-41a2-bcb5-80e26c3adec7`
- Application trace: `ec4520d704b4d8706412c27552c596aa`
- Job: `ba5b6823-d649-404b-9913-23435e2488d9`
- Job event: `ed5ff196-1bea-447c-8239-f545e808dc19`
- Job trace: `ba0eb8d9d89fee251de3dfebd73ece9d`

Grafana returned the application and job traces by exact trace ID. A bounded
TraceQL query for the MedTracker `observability.canary` span returned four
traces, including both corrected-endpoint canary traces. Loki returned the
application event by exact event ID on the exact deployed image.

### Safe request

- Request: `eaf38762-cb3f-4dda-a67b-6c9753938054`
- Request event: `d27a6349-fed4-4f17-9fea-5ce684b9ddfe`
- Request trace: `bab0e8a01f3a9915d7e0d8baa6b32bde`
- Span count: `18`

The exact request trace contained a root span and nested child spans. The
bounded attribute-key inspection found no medication, person, household,
credential, token, cookie, authorization, request-body, or raw model identifier
keys. Loki returned the same trace identifier on the request event.

Grafana reported Tempo, Loki, and Prometheus healthy. Tempo-to-Loki correlation
was configured against Loki UID `loki` with trace-ID filtering. Loki's live
derived field used Tempo UID `tempo`, the canonical trace-ID expression, and
the literal `${__value.raw}` query macro.

The application-owned canary process was attached to the pod's collected stdout
before emission because output written only to a `kubectl exec` stream is not
collected by the node log pipeline. This is an operator-procedure follow-up, not
a trace-backend failure.

This evidence contains only opaque identifiers, immutable revisions, counts,
configuration state, and pass/fail results. It contains no trace payload,
medication, person, household, credential, or raw domain identifier.
