# UniFi radio monitoring

Flux manages UnPoller 5.2.7, its ServiceMonitor, Grafana provisioning and
Alertmanager routes. No automatic network remediation is configured.

## Before deployment

Create a dedicated local UniFi identity with read-only Network access and
an API key. Store that key in the `home-ops` 1Password vault, item `unpoller`,
field `API_KEY`. Do not reuse the external-dns key: it has write capabilities.
Verify the account can read device and client statistics without granting
configuration access. The exporter also reads clients internally; this release
cannot disable that request, but the ServiceMonitor drops all client metrics.

The controller URL is `https://unifi.ironstone.casa`, with TLS verification
enabled. The egress policy allows HTTPS only to its current address,
`192.168.1.254`, and DNS to CoreDNS. Update policy if that address changes.
No public route exposes the exporter; only monitoring vmagent pods may scrape it.

Merge and reconcile through the usual reviewed Flux workflow. Do not apply
these resources manually. The three Grafana rules are initially paused;
after validating fresh scrapes, set `isPaused: false` in a second reviewed Git
change. Do not merge until the dedicated credential exists.

## Alerts

- Warning: five-minute mean above 80% for 10 minutes; no notifications.
- Critical: five-minute mean above 95% for 5 minutes; existing critical phone route.
- Telemetry unavailable: failed scrape, cache age >=90 seconds, never-populated
  cache, no radio metrics, or a radio observed during the previous 24 hours
  disappearing, sustained for five minutes; no notifications.

Every AP radio is included, even with zero ordinary clients. Thresholds use
fractions, not percentages. No clamping hides anomalous readings above 100%.
Site, AP name, MAC, band and radio identify notification groups, not exporter job.
Ordinary warnings outside this alert group retain their existing routing.

Congestion evaluation requires a fresh exporter cache and a successful scrape.
Grafana keeps the previous state on query-wide no-data or errors. Grafana can
still evict individual missing series; a resolved notification during missing
telemetry is not evidence of recovery. Check the separate telemetry alert.
Exporter freshness measures controller polling, not the freshness of each AP's
inform message. That is a remaining observability limitation.

## Dashboard and limitations

Network / UniFi Radio Health shows raw and averaged channel utilisation,
receive/transmit airtime, channel, radio retry observations, cache age and
scrape availability. Radio retry values are gauges, not monotonic counters.

This exporter does not expose the mesh-backhaul signal or dedicated mesh retry
fields seen in the controller API. They are deliberately not replaced with
client signal or ordinary radio retry metrics. Use the read-only UniFi
diagnostic for those fields pending upstream exporter support.

Never disable PoE on USW-Lite-8-PoE port 1 remotely: that port powers U6-Mesh,
which provides the switch's management path. See the 19 September incident.

## Verification

With `yq`, `promtool` and `amtool` on PATH, run:

```sh
bash tests/monitoring/check-unifi-alerts.sh
```

The test translates the provisioned Grafana numeric queries, thresholds and
pending periods into Prometheus rules. It exercises saturation, recovery,
brief spikes, warning-only load, stale cache, exporter absence and a missing
radio, then tests the actual routing tree with inert receivers. This does not
test Grafana's KeepLast state machine or prove physical phone delivery.

Before enabling notifications, verify ExternalSecret and HelmRelease readiness,
six current radio series for the three active APs, cache age below 90 seconds,
scrape interval 30 seconds, correct dashboard units and no unexpected client
series. In Grafana confirm all three rules evaluate without errors. Do not
create network congestion to test delivery; use the existing contact-point
test only with explicit approval for a test phone notification.

Local implementation validation used the release binary against the real
controller with TLS verification, Helm rendering and Grafana 12.3.1 in an
isolated container without production contact points. No live deployment or
phone notification was performed.
