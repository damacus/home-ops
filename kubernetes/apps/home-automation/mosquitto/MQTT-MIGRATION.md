# MQTT authentication migration

The broker requires authentication and loads the topic ACLs from the
GitOps-managed mosquitto-policy ConfigMap. Home Assistant, Frigate and GrowHAT
were verified with separate usernames before this final cutover.

The steps below record the migration order and its rollback checks.

## Historical migration prerequisites

1. Inventory all connected clients, including ones absent from recent logs.
2. Create a `mqtt-auth` item in the `home-ops` 1Password vault with private fields
   `homeassistant_password`, `frigate_password`, `growhat_password`, and
   `password_file`. The last field contains Mosquitto-generated password hashes
   for users `homeassistant`, `frigate`, and `growhat`. Never commit plaintext or hashes.
3. Verify Growhat SSH access and its actual device ID/discovery topics. Current
   logs show client ID `growhat_grow_pi_zero_w`; confirm before using the final ACLs.

## Historical credential and client migration

1. Merge the credential-staging GitOps changes only after the vault item exists.
   Verify both ExternalSecrets, broker readiness and Frigate MQTT connectivity.
2. Reconfigure Home Assistant's existing MQTT integration with username
   `homeassistant` and its password. Preserve its broker address and discovery.
3. Back up Growhat's live config and service definition. Add username `growhat`
   and `password_file` to its existing `[mqtt]` table. Store the password in a
   service-user-owned file with mode 0600. Validate using `check-config` before
   restarting the existing service. Do not run another hardware instance or send
   pump commands. Keep a protected rollback copy.
4. Verify authenticated connections for all three usernames, fresh sensor data,
   discovery, availability, Frigate events and existing Home Assistant alerts.

## Historical final cutover

The final GitOps change replaced the inline broker configuration with
`app/mosquitto-final.conf` and mounted `app/acl.conf` as
`/mosquitto/config/acl.conf`. Live client identities and discovery topics were
checked first. The isolated broker checks cover rejected anonymous connections,
wrong passwords, forbidden cross-client reads/publishes and allowed access.

Run `rtk proxy python3 tests/check_mqtt_acl.py` for isolated broker checks.
The harness uses dummy credentials and does not expose a host port.

## Live rollout verification

After Flux applies the final change, verify all three clients reconnect with
usernames, anonymous connections fail, and fresh GrowHAT telemetry and Frigate
messages still arrive. Preserve the broker persistence volume and retained
discovery data.
Rollback uses the prior GitOps revision and the protected client configurations.

## Transport and network access

Growhat currently supports MQTT over TCP without TLS. Credentials therefore
need a trusted, restricted network path. Follow up with LAN firewall rules and
workload network policies using the verified physical controller source address;
recent source IPs may be NATed. Do not assume a hostname provides isolation.
