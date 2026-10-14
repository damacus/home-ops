# Retired Reolink ONVIF relay

Retired on 14 October 2026 after the battery second-generation Reolink doorbell
failed the physical two-way audio test and dropped its RTSP source connection.
The deployment and its GitOps entry have been removed.

Keep both existing UniFi Protect camera records to retain access to their recordings.
Do not unmanage or delete either camera as part of this cleanup.
Frigate retains a disabled `doorbell` camera for historical recordings. Its existing
retention policy still applies; this is not a permanent archive. No media or database
PVC is deleted or moved. Birdy remains active.

The Reolink and test Scrypted HA integrations, talkback dashboard, HACS integration
and card are removed. The obsolete restricted account is revoked; its 1Password
item is retained pending archival because desktop authorisation timed out. The original Reolink credential is retained for device return/reset.
Scrypted and its MCP gateway remain available as independent shared services.

See [Nest restoration plan](../home-assistant/NEST-RESTORATION.md).
