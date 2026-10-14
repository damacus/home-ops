# Restore the first-generation Nest doorbell to Home Assistant

## Scope and capability boundary

Use the native Nest integration for live viewing, doorbell presses and supported
motion/person events. Keep Pixel picture notifications as the initial target;
Laura's notifications remain off until explicitly requested.
Google's legacy-doorbell SDM API does not expose a talkback command. This plan
must not promise two-way conversation inside the Home Assistant Companion app.
The working native Nest experience remains the baseline for answering the door.

## Existing state checked on 14 October 2026

Home Assistant runs 2026.10.1. A Nest config entry exists but is not loaded; its
stored data and options are empty. A Nest OAuth application credential imported
from configuration.yaml still exists, although no top-level Nest YAML block remains.
No Nest-specific error appeared in the inspected startup logs. The credential may
be reusable; its validity and the Google Cloud/Device Access projects are unverified.
Inspect these before creating or deleting cloud resources. Keep the existing entry
until its role is understood.

## Recovery sequence

1. Reinstall the Nest Hello and confirm its native live view, chime and conversation.
   Identify whether it remains in Nest or has been transferred to Google Home.
2. Inspect existing Home Assistant application credentials, Google Cloud project,
   Device Access project and Pub/Sub topic using the owning personal Google account.
   Google Workspace and Advanced Protection have documented compatibility limits.
3. Reuse valid existing resources. Enable SDM and Pub/Sub APIs in the chosen Cloud
   project. Configure a Web OAuth client with redirect
   `https://my.home-assistant.io/redirect/oauth`. Store any newly generated secret in
   1Password. Use an External consent app in Production to avoid seven-day Testing
   token expiry. Google consent and any payment/terms require owner interaction.
4. Check the January 2025 Pub/Sub change: existing working topics can be retained;
   new or re-enabled event setups need a user-created topic. Grant Google's documented
   SDM publisher principal Pub/Sub Publisher on that topic only, then enter the exact
   full topic name in Device Access and Home Assistant. Verify the current principal
   from Google's documentation at implementation time; do not grant project-wide roles
   or weaken organisation policies as a workaround.
5. Complete HA's Nest setup/reauthentication with the existing Device Access project,
   Cloud project, topic/subscription and OAuth credentials. Do not pay the Device
   Access registration fee again if the owner is already enrolled.
6. Test a physical button press, one Pixel picture notification, event image retrieval,
   local and mobile-data live viewing, and recovery after an HA restart. Verify session
   renewal rather than storing a temporary RTSP URL as a permanent Frigate source.
7. Only after the integration works, replace the retired notification automation with
   the actual Nest event/entity identifiers. Do not add Scrypted, Frigate or Protect
   forwarding unless it is separately needed and demonstrated to work.

## Acceptance and unresolved inputs

Not deployed: this is a plan. Need the owning Google account/project inventory and
the reinstalled doorbell. If a Google policy blocks Pub/Sub publishing, capture the
exact policy/error first; a generic security-change explanation is not sufficient.
Cloud permission changes are outside this cleanup and require a concrete scoped plan.

## Primary references

- https://www.home-assistant.io/integrations/nest/
- https://developers.google.com/nest/device-access/api/doorbell
- https://developers.google.com/nest/device-access/subscribe-to-events
