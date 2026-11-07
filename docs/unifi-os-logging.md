# UniFi OS logging

The dedicated Vector receiver writes to Loki with `job="unifi-os"`. The
Network / UniFi OS Logs dashboard shows matching messages and an unfiltered view.
Its filters are starting points and should be checked against actual messages.

On the inspected UDM Pro, Network's **Integrations → System Logging / SIEM**
offers a server address, port, event categories and **Include Raw Logs**. The
interface does not identify which raw sources are included or offer a protocol
selector. The existing setting was **Internally Stored**; it was not changed.
The console runs syslog-ng and writes kernel messages locally to
`/var/log/kern.log`. Neither observation establishes that the SIEM export includes
raw kernel messages.

The receiver exposes UDP syslog on `192.168.3.10:514`, restricted to
`192.168.1.254`, and buffers up to 512 MiB on a persistent 1 GiB volume. UDP
can lose messages before they reach Vector, including during outages or when
the buffer is full. Vector exports internal error and drop metrics on port 9090.
Five-minute alerts cover storage I/O, filesystem corruption and journal failures,
Ethernet SRAM parity and out-of-memory kills. MDIO messages remain searchable
but do not alert. No log contents are copied into alert labels.

Deploy and validate the receiver before enabling export. Confirm the actual
transport and message format. The Network UI's SIEM categories cover application
events; verify raw kernel messages separately before relying on the feed. If kernel
messages are missing, stop activation and report the gap before adding a custom
collector.

Keep historical incident excerpts separate from live alerts. Loki currently
rejects samples older than seven days, even though its retention period is
fourteen days; do not change those limits just to import old fixtures. Any
historical test streams must have an explicit label excluded by every live rule.
Remote forwarding may also miss early boot events and network outages, so retain
the incident logs and configuration backup independently.
