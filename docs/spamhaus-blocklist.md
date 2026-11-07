# Spamhaus block list

The publisher downloads Spamhaus DROP and DROPv6 once a day. It checks each
CIDR and the source record count before publishing the two feeds together.
IPv4 prefixes broader than /8 and IPv6 prefixes broader than /16 are rejected
to prevent a single unexpectedly broad entry from cutting off the internet.
Failed downloads or invalid data leave the previous generation in place. The
`spamhaus-data` PVC retains that generation across pod restarts. The static
server is reachable only through the internal Traefik route.

After the Flux resources are deployed, allow the first scheduled run or start
one job from the CronJob. Check the job, both text URLs and the metrics URL:

* `https://spamhaus.ironstone.casa/current/drop_v4.txt`
* `https://spamhaus.ironstone.casa/current/drop_v6.txt`
* `https://spamhaus.ironstone.casa/current/metrics.txt`

Confirm the PVC is bound, the job can write as UID/GID 10001, and the HTTP pod
can read the resulting files before creating UniFi lists. The NFS driver's
`fsGroupPolicy` and server export permissions determine whether that ownership
works; a successful manifest dry run does not verify a real mount or write.
Investigate mount permissions without making the shared export world-writable.

The unmodified source feeds are available alongside them as `drop_v4.json`
and `drop_v6.json`. `SpamhausFeedStale` alerts when the last successful
publication is over 48 hours old. `SpamhausFeedUnavailable` alerts when the
metrics cannot be scraped after the first scheduled run, or when the CronJob
is missing. Before the first publication, the stale alert uses the CronJob's
creation time. If endpoint metrics are unavailable, it falls back to the last
successful CronJob time, then the creation time. If the endpoint is unavailable, verify UniFi's
actual cached list and firewall behaviour; the publisher cannot guarantee it.

## UniFi configuration

Verify UniFi OS is at least 6.0.10 and Network supports external Network Lists.
Confirm the UDM can resolve the internal hostname and trust its certificate.
Create separate IPv4 and IPv6 external Network Lists using the two text URLs.
Check their imported counts against the current files; confirm a later refresh
also succeeds. Do not assume the controller supports Spamhaus JSON directly.

For each IP version, create Block policies with protocol All and the
corresponding list in the external side of each zone pair:

| Source zone | Destination zone | List location |
| --- | --- | --- |
| External | Internal | Source |
| Internal | External | Destination |
| External | Gateway | Source |
| Gateway | External | Destination |
| External | Vpn | Source |
| Vpn | External | Destination |

Recheck zone membership, enabled VPN routes and existing policies after any
network changes. Include additional internet-facing zones if they become used.
Place each block above matching allow and return-traffic policies in that zone
pair. Preserve the existing IPv6 and ICMPv6 firewall protections.

Before enabling production policies, verify controlled listed and unlisted
test addresses for both IP versions and directions. Check DNS, normal browsing,
VPN, gateway services and published services. Test the impact on established
sessions and confirm the list remains populated after an endpoint outage.
Disable the new policies to roll back; do not remove the baseline firewall.

The existing UniFi MCP deployment disables policy create, update and delete.
Do not bypass those settings. Use an authorised administrative workflow for
the UniFi changes and read the policies back after applying them.
