"""Synthetic HA-style tools; never connects to Home Assistant."""
from mcp.server.mcpserver import MCPServer

server = MCPServer("home-assistant-fixture")
state = {"light": "off"}


@server.tool()
def get_state() -> str:
    """Read a synthetic device."""
    return state["light"]


@server.tool()
def set_state(value: str) -> str:
    """Change a synthetic device."""
    state["light"] = value
    return value


server.run(transport="streamable-http", host="0.0.0.0", port=8000,
           stateless_http=True, json_response=True)
