## Canary exporter outage and rollback

- Outage test started: `2026-07-30T15:47:20Z`
- Scope: MedTracker canary only
- Production exporter: remained disabled

The canary trace endpoint was temporarily changed to a nonexistent internal
service. The canary deployment remained ready.

- Safe request: `8544b7b9-d0bf-455d-be44-9ef5a991365d`
- Request outcome: HTTP 200 and canonical request success
- Safe workflow: `b1c5a9cc-8a1f-430e-8116-d182172329d9`
- Application event: `c342524f-1ebe-4652-9d13-9ab8baa00688`
- Job: `231afd67-9f2b-4fc4-bdc6-2ddaa7200318`
- Job event: `a7e62c95-09cb-48e3-b1cd-79a8c8578a22`
- Job outcome: completed successfully
- Trace flush result: failed as expected
- Failure signal: bounded `medtracker.opentelemetry` error events

The exact tested `/v1/traces` endpoint was then restored. Server-side field
ownership was returned to `kustomize-controller`, the generated Secret matched
the Git contract, and the canary was restarted.

- Recovery started: `2026-07-30T15:49:33Z`
- Recovery event: `cbcc5c5f-9b24-4ac4-858c-73c35ee697cd`
- Recovery trace: `7d1c6eb9b8e64d20a7b5605e99c7c619`
- Trace flush result: success
- Tempo lookup: success

This evidence contains only opaque identifiers, timestamps, outcomes, and
configuration state. It contains no trace payload, medication, person,
household, credential, or raw domain identifier.
