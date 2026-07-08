# Home Assistant Assist MCP

Home Assistant exposes its MCP server at:

```text
https://home-assistant.ironstone.casa/api/mcp
```

The Home Assistant MCP Server uses Streamable HTTP and requires authentication.
Clients only see entities that are exposed to the selected Assist pipeline.

## Current State

The live `mcp_server` config entry exists and is enabled:

```json
{"title":"Assist","disabled_by":null,"data":{"llm_hass_api":["assist"]},"options":{}}
```

This means the MCP server is bound to the `Assist` LLM Home Assistant API. The
Assist exposure store currently has no entities with `should_expose: true`. It
does contain entries for the new PowerCalc area energy entities, but they are
not exposed yet.

Do not directly edit Home Assistant `.storage` files such as
`/config/.storage/core.config_entries` or
`/config/.storage/homeassistant.exposed_entities`. Treat them as read-only
verification evidence and make exposure changes through the Home Assistant UI.

## Expose Read-Only Power Sensors

1. Open Home Assistant.
2. Go to Settings > Voice assistants.
3. Open Expose.
4. Select Assist.
5. Expose only these read-only sensor entities:
   - `sensor.downstairs_lights_power`
   - `sensor.downstairs_lights_energy`
   - `sensor.main_bedroom_lights_area_power`
   - `sensor.main_bedroom_lights_area_energy`
   - `sensor.outdoor_lights_power`
   - `sensor.outdoor_lights_energy`
   - `sensor.loft_lights_area_power`
   - `sensor.loft_lights_area_energy`
   - `sensor.washing_machine_current_consumption`
   - `sensor.washing_machine_today_s_consumption`
   - `sensor.tv_socket_current_consumption`
   - `sensor.tv_socket_today_s_consumption`
   - `sensor.office_switch_current_consumption`
   - `sensor.office_switch_today_s_consumption`
   - `sensor.rack_switch_power`
   - `sensor.rack_switch_energy`
   - `sensor.spare_power`
   - `sensor.spare_energy`
6. Save the exposure changes.

For this first power-insight use case, do not expose controllable entities:
`light.*`, `switch.*`, `cover.*`, `lock.*`, `climate.*`,
`alarm_control_panel.*`, or alarm/control entities. Keep Assist/MCP scoped to
read-only power and energy sensors until there is a separate control-oriented
review.

## Create a Token

1. Open the user profile page in Home Assistant.
2. Under Security, create a long-lived access token named
   `codex-home-assistant-mcp`.
3. Store it in the local environment as `HOMEASSISTANT_TOKEN`.

Do not commit the token or write it into repository files.

## Direct Streamable HTTP Client Config

Use this shape for MCP clients that support remote Streamable HTTP directly:

```json
{
  "mcpServers": {
    "homeassistant": {
      "serverUrl": "https://home-assistant.ironstone.casa/api/mcp",
      "headers": {
        "Authorization": "Bearer ${HOMEASSISTANT_TOKEN}"
      }
    }
  }
}
```

## Stdio-Only mcp-proxy Client Config

Use this shape for clients that only support stdio MCP servers:

```json
{
  "mcpServers": {
    "homeassistant": {
      "command": "mcp-proxy",
      "args": [
        "--transport=streamablehttp",
        "--stateless",
        "https://home-assistant.ironstone.casa/api/mcp"
      ],
      "env": {
        "API_ACCESS_TOKEN": "${HOMEASSISTANT_TOKEN}"
      }
    }
  }
}
```

If the client does not expand environment placeholders inside `env`, launch the
client from a shell where `API_ACCESS_TOKEN` is already set from
`HOMEASSISTANT_TOKEN`.

## Endpoint Checks

No token should fail:

```bash
curl -i https://home-assistant.ironstone.casa/api/mcp
```

Expected: `401 Unauthorized` or another authentication failure.

With a token:

```bash
curl -i \
  -H "Authorization: Bearer ${HOMEASSISTANT_TOKEN}" \
  https://home-assistant.ironstone.casa/api/mcp
```

Expected: not `401`. Raw `curl` may still return a method, protocol, or
content-type error because MCP clients speak the MCP protocol over this endpoint.
For this check, the important result is that Home Assistant accepted the bearer
token.

## Fallback When Codex Cannot Attach MCP

If the current Codex environment cannot attach a user MCP server, use the
Home Assistant REST states API for the first read-only audit pass:

```bash
curl -fsS \
  -H "Authorization: Bearer ${HOMEASSISTANT_TOKEN}" \
  -H "Content-Type: application/json" \
  https://home-assistant.ironstone.casa/api/states/sensor.downstairs_lights_energy
```

This fallback is read-only and enough for power insight reports. Enable MCP
later in the desktop app or host settings using one of the configurations above.
