# Home Assistant Power Groups

PowerCalc light sensors are grouped so Home Assistant can show useful totals without
double-counting the same lights.

The hierarchy is:

1. Leaf sensors measure or estimate individual lights and devices.
2. Room groups aggregate leaves for one room, such as `sensor.kitchen_lights_energy`.
3. Area groups aggregate room groups and are the only light energy sensors that should be added to the Energy Dashboard.

Only top-level area energy sensors belong in the Energy Dashboard. Adding both a room
sensor and its area parent counts the same child energy twice.

## Group Hierarchy

- Downstairs light fixtures: Kitchen light fixtures, Living room light fixtures, Hall light fixtures.
- Upstairs light fixtures: main bedroom light fixtures, Harrison's bedroom lights, bedroom four lights, and landing lights.
- Outdoor lights: Garden lights, Porch lights.
- Loft lights: Loft ambiance.
- Sonos speakers: Playroom SYMFONISK, Kitchen One SL, and Living room Sonos Beam.

Jack's bedroom is part of upstairs, but it does not currently have a Jack or
Bedroom 3 PowerCalc energy sensor. Add that room to `Upstairs light fixtures` after a
PowerCalc room sensor exists for it.

## Energy Dashboard Sensors

Add these as individual devices:

- `sensor.downstairs_light_fixtures_energy`
- `sensor.upstairs_light_fixtures_energy`
- `sensor.outdoor_lights_energy`
- `sensor.loft_lights_energy`
- `sensor.sonos_speakers_energy`

## UI Steps

Make live Energy Dashboard changes through the Home Assistant UI. Do not directly edit
`/config/.storage/energy`; it is Home Assistant-managed storage, not stable source
configuration.

1. Open Home Assistant.
2. Go to Settings > Dashboards > Energy.
3. Under Individual devices, choose Add device.
4. Add each area energy sensor listed above.
5. Save the Energy configuration.
6. Wait for the Energy dashboard statistics card to refresh.

Remove `sensor.downstairs_lights_energy_2` and `sensor.upstairs_lights_energy`
if they are currently configured. Those legacy groups use polluted room
aggregate history and produce unrealistic totals in the Energy Dashboard.

If verification does not show all five grouped sensors, complete the UI steps above with
an authenticated Home Assistant user session. The sensors can exist in Home Assistant
state and PowerCalc storage before they are added to the Energy Dashboard.

## Verification

After the UI changes are saved, inspect the Home Assistant Energy Dashboard storage:

```bash
kubectl exec -n home-automation home-assistant-0 -- cat /config/.storage/energy \
  | jq -r '.. | strings | select(startswith("sensor."))' \
  | sort
```

The output should include the five grouped sensors listed above:

```text
sensor.downstairs_light_fixtures_energy
sensor.loft_lights_energy
sensor.sonos_speakers_energy
sensor.outdoor_lights_energy
sensor.upstairs_light_fixtures_energy
```

Home Assistant already has older GUI-created downstairs, kitchen, and upstairs
light group entities with polluted history. The Energy Dashboard should use the
package-managed fixture entities instead.

The output should not include child room sensors as Energy Dashboard individual
devices:

```text
sensor.kitchen_lights_energy
sensor.living_room_lights_energy
sensor.hall_lights_energy
sensor.kitchen_light_fixtures_energy
sensor.living_room_light_fixtures_energy
sensor.hall_light_fixtures_energy
sensor.main_bedroom_energy
sensor.harrison_s_bedside_lamp_energy
sensor.harrison_s_colour_bulb_energy
sensor.big_spare_bedroom_light_energy
sensor.landing_ambiance_energy
sensor.landing_ambiance_2_energy
sensor.garden_lights_energy
sensor.porch_energy
sensor.loft_ambiance_energy
```
