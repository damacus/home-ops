#!/usr/bin/env python3
"""Read-only UniFi diagnostics for mesh/backhaul investigations."""

from __future__ import annotations

import argparse
import json
import platform
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Final


DEFAULT_CONTROLLER: Final[str] = "https://192.168.1.254"
DEFAULT_SITE: Final[str] = "default"
DEFAULT_SECRET_NAMESPACE: Final[str] = "network"
DEFAULT_SECRET_NAME: Final[str] = "external-dns-unifi-secret"
DEFAULT_SECRET_KEY: Final[str] = "api-key"

DEFAULT_DEVICES: Final[tuple[str, ...]] = (
    "U6-LR",
    "U6-Mesh",
    "U6 Pro",
    "USW-Lite-8-PoE",
)

DEFAULT_WATCH_IPS: Final[tuple[str, ...]] = (
    "U6-LR=192.168.1.155",
    "U6-Mesh=192.168.1.109",
    "USW-Lite-8-PoE=192.168.1.38",
    "Garage=192.168.1.168",
)

DEFAULT_CLIENT_MACS: Final[tuple[str, ...]] = (
    "70:a7:41:5f:13:d9",
)


@dataclass(frozen=True)
class PingResult:
    name: str
    ip: str
    ok: bool
    detail: str


class UnifiError(RuntimeError):
    """Raised when UniFi data cannot be collected."""


def parse_csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_watch_ips(value: str) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for item in parse_csv(value):
        if "=" in item:
            name, ip = item.split("=", 1)
        elif ":" in item:
            name, ip = item.split(":", 1)
        else:
            name = item
            ip = item
        entries.append((name.strip(), ip.strip()))
    return entries


def timestamp(value: Any) -> str:
    if not isinstance(value, int | float) or value <= 0:
        return "-"
    return datetime.fromtimestamp(value, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def value_or_dash(value: Any) -> str:
    if value is None or value == "":
        return "-"
    return str(value)


def state_label(value: Any) -> str:
    labels = {
        0: "offline",
        1: "online",
        11: "adopting/pending",
    }
    return labels.get(value, value_or_dash(value))


def run_kubectl_secret(namespace: str, name: str, key: str) -> str:
    jsonpath = f"{{.data.{key}}}"
    command = [
        "kubectl",
        "get",
        "secret",
        "-n",
        namespace,
        name,
        "-o",
        f"jsonpath={jsonpath}",
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise UnifiError(result.stderr.strip() or "kubectl secret read failed")

    decode = subprocess.run(
        ["base64", "-d"],
        input=result.stdout,
        check=False,
        capture_output=True,
        text=True,
    )
    if decode.returncode != 0:
        raise UnifiError(decode.stderr.strip() or "base64 decode failed")
    return decode.stdout.strip()


class UnifiClient:
    def __init__(self, controller: str, site: str, api_key: str) -> None:
        self.controller = controller.rstrip("/")
        self.site = site
        self.api_key = api_key
        self.context = ssl._create_unverified_context()

    def get(self, path: str) -> dict[str, Any]:
        url = f"{self.controller}{path}"
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/json",
                "X-API-KEY": self.api_key,
            },
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=20) as response:
                body = response.read().decode("utf-8")
        except urllib.error.URLError as exc:
            raise UnifiError(f"UniFi request failed for {url}: {exc}") from exc
        return json.loads(body)

    def devices(self) -> list[dict[str, Any]]:
        payload = self.get(f"/proxy/network/api/s/{self.site}/stat/device")
        return list(payload.get("data", []))

    def clients(self) -> list[dict[str, Any]]:
        payload = self.get(f"/proxy/network/api/s/{self.site}/stat/sta")
        return list(payload.get("data", []))


def ping_targets(targets: list[tuple[str, str]]) -> list[PingResult]:
    results: list[PingResult] = []
    wait_arg = "1000" if platform.system() == "Darwin" else "1"
    for name, ip in targets:
        command = ["ping", "-c", "1", "-W", wait_arg, ip]
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        detail = "reachable" if result.returncode == 0 else summarize_ping_failure(result)
        results.append(PingResult(name=name, ip=ip, ok=result.returncode == 0, detail=detail))
    return results


def summarize_ping_failure(result: subprocess.CompletedProcess[str]) -> str:
    output = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
    if "No route to host" in output:
        return "no route to host"
    if "100.0% packet loss" in output or "100% packet loss" in output:
        return "timeout"
    return output.splitlines()[-1] if output else f"ping exited {result.returncode}"


def find_named_devices(devices: list[dict[str, Any]], names: list[str]) -> list[dict[str, Any]]:
    by_name = {str(device.get("name", "")): device for device in devices}
    return [by_name[name] for name in names if name in by_name]


def find_clients(
    clients: list[dict[str, Any]],
    watch_ips: list[tuple[str, str]],
    macs: list[str],
) -> list[dict[str, Any]]:
    ip_set = {ip for _, ip in watch_ips}
    mac_set = {mac.lower() for mac in macs}
    matches: list[dict[str, Any]] = []
    for client in clients:
        client_ip = str(client.get("ip", ""))
        client_mac = str(client.get("mac", "")).lower()
        if client_ip in ip_set or client_mac in mac_set:
            matches.append(client)
    return matches


def print_table(headers: list[str], rows: list[list[Any]]) -> None:
    text_rows = [[value_or_dash(value) for value in row] for row in rows]
    widths = [
        max(len(header), *(len(row[index]) for row in text_rows)) if text_rows else len(header)
        for index, header in enumerate(headers)
    ]
    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    print("  ".join("-" * width for width in widths))
    for row in text_rows:
        print("  ".join(row[index].ljust(widths[index]) for index in range(len(headers))))


def print_device_summary(devices: list[dict[str, Any]]) -> None:
    print("Devices")
    print_table(
        ["name", "state", "ip", "model", "version", "last_seen", "disconnected_at"],
        [
            [
                device.get("name"),
                state_label(device.get("state")),
                device.get("ip"),
                device.get("model"),
                device.get("version"),
                timestamp(device.get("last_seen")),
                timestamp(device.get("disconnected_at")),
            ]
            for device in devices
        ],
    )
    print()


def print_radio_summary(devices: list[dict[str, Any]]) -> None:
    rows: list[list[Any]] = []
    for device in devices:
        for radio in device.get("radio_table", []) or []:
            rows.append(
                [
                    device.get("name"),
                    radio.get("radio"),
                    radio.get("name"),
                    radio.get("channel"),
                    radio.get("ht"),
                    radio.get("tx_power"),
                    radio.get("tx_power_mode"),
                    radio.get("vwire_enabled"),
                ]
            )
    print("AP radios")
    print_table(["device", "band", "radio", "channel", "width", "tx_power", "tx_mode", "mesh"], rows)
    print()


def print_wireless_uplinks(devices: list[dict[str, Any]]) -> None:
    rows: list[list[Any]] = []
    for device in devices:
        uplink = device.get("uplink") or {}
        if uplink.get("type") == "wireless":
            rows.append(
                [
                    device.get("name"),
                    uplink.get("uplink_device_name") or uplink.get("uplink_mac"),
                    uplink.get("radio"),
                    uplink.get("channel"),
                    uplink.get("signal"),
                    uplink.get("rssi"),
                    uplink.get("tx_rate"),
                    uplink.get("rx_rate"),
                    uplink.get("is_mesh_v3"),
                ]
            )
    print("Active wireless uplinks")
    print_table(["device", "parent", "band", "channel", "signal", "rssi", "tx_rate", "rx_rate", "mesh_v3"], rows)
    print()


def print_peer_observations(devices: list[dict[str, Any]]) -> None:
    rows: list[list[Any]] = []
    for device in devices:
        for peer in device.get("uplink_table", []) or []:
            rows.append(
                [
                    device.get("name"),
                    peer.get("mac"),
                    peer.get("radio"),
                    peer.get("channel"),
                    peer.get("signal"),
                    peer.get("rssi"),
                    peer.get("noise"),
                ]
            )
    print("Wireless peer observations")
    print_table(["observer", "peer_mac", "band", "channel", "signal", "rssi", "noise"], rows)
    print()


def print_switch_ports(devices: list[dict[str, Any]]) -> None:
    rows: list[list[Any]] = []
    for device in devices:
        for port in device.get("port_table", []) or []:
            if port.get("port_idx") not in (1, 4):
                continue
            rows.append(
                [
                    device.get("name"),
                    port.get("port_idx"),
                    port.get("name"),
                    port.get("up"),
                    port.get("speed"),
                    port.get("poe_power"),
                    port.get("poe_voltage"),
                    port.get("rx_errors"),
                    port.get("tx_errors"),
                    port.get("rx_dropped"),
                    port.get("tx_dropped"),
                    port.get("link_down_count"),
                ]
            )
    if not rows:
        return
    print("Switch ports of interest")
    print_table(
        [
            "switch",
            "port",
            "name",
            "up",
            "speed",
            "poe_w",
            "poe_v",
            "rx_err",
            "tx_err",
            "rx_drop",
            "tx_drop",
            "link_down",
        ],
        rows,
    )
    print()


def print_client_summary(clients: list[dict[str, Any]]) -> None:
    if not clients:
        return
    print("Clients of interest")
    print_table(
        ["name", "hostname", "ip", "mac", "ap_mac", "sw_mac", "uptime", "last_seen"],
        [
            [
                client.get("name"),
                client.get("hostname"),
                client.get("ip"),
                client.get("mac"),
                client.get("ap_mac"),
                client.get("sw_mac"),
                client.get("uptime"),
                timestamp(client.get("last_seen")),
            ]
            for client in clients
        ],
    )
    print()


def print_ping_summary(results: list[PingResult]) -> None:
    print("Reachability")
    print_table(
        ["name", "ip", "status", "detail"],
        [[result.name, result.ip, "ok" if result.ok else "fail", result.detail] for result in results],
    )
    print()


def build_payload(
    selected_devices: list[dict[str, Any]],
    selected_clients: list[dict[str, Any]],
    pings: list[PingResult],
) -> dict[str, Any]:
    return {
        "collected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "devices": selected_devices,
        "clients": selected_clients,
        "reachability": [result.__dict__ for result in pings],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", default=DEFAULT_CONTROLLER)
    parser.add_argument("--site", default=DEFAULT_SITE)
    parser.add_argument("--secret-namespace", default=DEFAULT_SECRET_NAMESPACE)
    parser.add_argument("--secret-name", default=DEFAULT_SECRET_NAME)
    parser.add_argument("--secret-key", default=DEFAULT_SECRET_KEY)
    parser.add_argument("--devices", default=",".join(DEFAULT_DEVICES))
    parser.add_argument("--watch-ips", default=",".join(DEFAULT_WATCH_IPS))
    parser.add_argument("--client-macs", default=",".join(DEFAULT_CLIENT_MACS))
    parser.add_argument("--json", action="store_true", help="Print raw selected data as JSON")
    parser.add_argument("--no-ping", action="store_true", help="Skip local ICMP reachability checks")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    device_names = parse_csv(args.devices)
    watch_ips = parse_watch_ips(args.watch_ips)
    client_macs = parse_csv(args.client_macs.lower())

    try:
        api_key = run_kubectl_secret(args.secret_namespace, args.secret_name, args.secret_key)
        client = UnifiClient(args.controller, args.site, api_key)
        devices = client.devices()
        clients = client.clients()
    except UnifiError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1

    selected_devices = find_named_devices(devices, device_names)
    selected_clients = find_clients(clients, watch_ips, client_macs)
    pings = [] if args.no_ping else ping_targets(watch_ips)

    if args.json:
        print(json.dumps(build_payload(selected_devices, selected_clients, pings), indent=2, sort_keys=True))
        return 0

    print(f"Collected at {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print()
    print_device_summary(selected_devices)
    print_radio_summary(selected_devices)
    print_wireless_uplinks(selected_devices)
    print_peer_observations(selected_devices)
    print_switch_ports(selected_devices)
    print_client_summary(selected_clients)
    if pings:
        print_ping_summary(pings)

    return 0


if __name__ == "__main__":
    sys.exit(main())
