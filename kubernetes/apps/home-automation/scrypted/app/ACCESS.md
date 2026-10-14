# Scrypted console access verification

Verified on 14 October 2026 against the live `scrypted-forward-auth` middleware
and `https://scrypted.ironstone.casa`. The route fix was applied for validation
before PR #4501 merged; these results do not imply GitOps reconciliation.

| Request | Observed result |
| --- | --- |
| No cookies or credentials: GET `/login` | HTTP 302 to Zitadel `/oauth/v2/authorize`; no native login data returned |
| No cookies or credentials: GET `/endpoint/@scrypted/core/public/` | HTTP 302 to Zitadel |
| Same two requests with an invalid bearer token and forged `X-Auth-Request-User: admin` | HTTP 302 to Zitadel; forged identity did not grant access |
| Valid SSO session without native Scrypted login | Native login form for `node-0b0715`; no configured device list exposed |
| Valid SSO and native Scrypted login, followed by browser reload | Doorbell device 29 at 192.168.1.17 loads; console version 0.147.0 and no persistent Disconnected warning |

The user completed native sign-in. The authenticated console also displayed all
six installed plugins. Anonymous requests were made with an independent HTTP
client without browser cookies. Redirect checks did not follow the sign-in flow.

The middleware retains the existing SSO authorisation check but does not copy
its Authorization or access-token response headers into requests to Scrypted.
Scrypted continues to require its own authentication. Neither credentials nor
SSO state parameters are included in this record.
