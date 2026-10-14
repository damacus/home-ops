# Nest doorbell press events through Google Home

## Agreed scope

Receive only Nest Hello doorbell presses in Home Assistant and reconnect the existing hall-light automation. The doorbell has not been reinstalled, so the physical press test remains pending. Keep Gmail Advanced Protection enabled. Laura's doorbell notifications remain disabled. Video, snapshots, talkback and Scrypted forwarding are outside this setup.

## Native Nest block

The original Cloud project is haas-318622 and Device Access project is a4135cb5-4d3c-4976-bb2b-441db99eb20d. Its Google-managed event topic remains enabled. Google rejected native HA OAuth with Error 400: policy_enforced because Gmail uses Advanced Protection. The documented block also applies to event-only access.

## Event path

Nest Hello -> Google Home DoorbellPress automation -> HA input_boolean -> existing hall-light automation.

Google Home's editor lists Hallway - Hallway for device.event.DoorbellPress. The old cloud-to-cloud project home-assistant-42748 already exists with a Home Assistant integration. Its haas.damacus.io URLs need the current public home-assistant.damacus.io host.

The GitOps package mounts /config/packages/nest-doorbell-relay.yaml and exposes only input_boolean.nest_doorbell_press to Google Assistant. It starts off and resets after every on command. Original automation 1657399874293 should use this helper's off-to-on state trigger, preserving its after-dark condition, Hallway Bright scene and ten-minute switch-off action.

report_state is disabled. The installed Home Assistant 2026.10.1 schema allows this connection without a service-account key. Automatic HomeGraph reporting and HA's request_sync service are unavailable; the initial Google SYNC still lists the helper. Relink or use Google's sync command if needed.

## Google account linking

Reuse the existing project and OAuth client ID:
https://oauth-redirect.googleusercontent.com/r/home-assistant-42748

Update the integration to these public endpoints:

- Authorisation: https://home-assistant.damacus.io/auth/authorize
- Token: https://home-assistant.damacus.io/auth/token
- Fulfilment: https://home-assistant.damacus.io/api/google_assistant

After package deployment and endpoint updates, use Pixel Google Home -> Devices -> Add -> Works with Google Home -> [test] Home Assistant. Sign in through Home Assistant's login screen. Only the dedicated helper should appear. Assign it to Hallway in Ironstone Road. Validate and activate this script using the editor's actual device names:

```yaml
metadata:
  name: Nest doorbell to Home Assistant
  description: Send doorbell presses to the existing Home Assistant automations.
automations:
  - starters:
      - type: device.event.DoorbellPress
        device: Hallway - Hallway
    actions:
      - type: device.command.OnOff
        devices: Nest doorbell press - Hallway
        on: true
```

## Acceptance and recovery

Check unauthenticated fulfilment is denied, authenticated SYNC returns only the helper, and a synthetic Google EXECUTE turns it on and HA resets it. Distinguish the synthetic test from a real Nest press. Confirm the old automation is available with the same conditions and actions.

The doorbell is offline because it has not been reinstalled. Afterwards, press it and verify Google's execution log and HA's trace. Test after dark for the original lighting behaviour and test a second press. Physical acceptance remains pending until then.

Before runtime changes, retain the original automations and helper registry in a private /config/backups/nest-events-20261014 archive. The legacy person-event automation remains outside this doorbell-press scope. Restore the saved hall-light configuration through HA's editor to roll back. Disable the Google Home routine before removing its relay.

## References

- https://www.home-assistant.io/integrations/nest/#google-advanced-protection-program
- https://support.google.com/accounts/answer/7539956
- https://developers.home.google.com/automations/schema/reference/entity/sht_device/doorbell_press_event
- https://www.home-assistant.io/integrations/google_assistant/
