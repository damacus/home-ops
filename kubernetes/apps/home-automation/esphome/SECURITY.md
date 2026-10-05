# ESPHome dashboard access

The dashboard hostname is protected by Traefik and the existing Zitadel
forward-auth middleware. The direct load-balancer address is removed.

## Remaining direct node access

ESPHome still uses host networking for mDNS discovery and OTA addressing.
The two live device configurations do not specify fixed addresses. Removing
host networking before migrating device addressing could break those features.
The dashboard can therefore still listen on its node IP at port 6052.
This change does not claim to close that bypass.

Complete the follow-up by creating dashboard authentication credentials in
1Password, exposing them through External Secrets, and enabling ESPHome's native
dashboard authentication. Alternatively, migrate device addressing and verify
OTA before removing host networking and restricting dashboard ingress to Traefik.
Do not rely only on removal of the load-balancer service or on a pod network
policy to secure a host-network listener. Verify applicable LAN firewall rules.
