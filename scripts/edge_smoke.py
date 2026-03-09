#!/usr/bin/env python3
"""Smoke tests for edge-routed services."""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import shutil
import socket
import ssl
import subprocess
import sys
from dataclasses import dataclass
from typing import Final


CURL_CANDIDATES: Final[tuple[str, ...]] = (
    "/opt/homebrew/opt/curl/bin/curl",
    "curl",
)


@dataclass(frozen=True)
class HttpCheck:
    name: str
    url: str
    expected_codes: tuple[int, ...] = (200, 301, 302, 308)


@dataclass(frozen=True)
class WebSocketCheck:
    name: str
    host: str
    path: str
    expect_substring: str
    port: int = 443


BASELINE_HTTP_CHECKS: Final[tuple[HttpCheck, ...]] = (
    HttpCheck("Home Assistant", "https://home-assistant.ironstone.casa/"),
    HttpCheck("code-server", "https://code.ironstone.casa/"),
    HttpCheck("Echo Server", "https://echo-server.ironstone.casa/"),
    HttpCheck("Trillium Next", "https://trillium-next.ironstone.casa/"),
)

ESPHOME_CANARY_HTTP_CHECKS: Final[tuple[HttpCheck, ...]] = (
    HttpCheck("ESPHome canary", "https://esphome-traefik.ironstone.casa/"),
)

WEBSOCKET_CHECKS: Final[tuple[WebSocketCheck, ...]] = (
    WebSocketCheck(
        name="Home Assistant WebSocket",
        host="home-assistant.ironstone.casa",
        path="/api/websocket",
        expect_substring="auth_required",
    ),
)


def supports_http3(curl_path: str) -> bool:
    try:
        result = subprocess.run([curl_path, "-V"], check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return False
    return "HTTP3" in result.stdout


def resolve_curl_path() -> str | None:
    for candidate in CURL_CANDIDATES:
        resolved = shutil.which(candidate) if "/" not in candidate else candidate
        if not resolved or not os.path.exists(resolved):
            continue
        if candidate == "/opt/homebrew/opt/curl/bin/curl" and supports_http3(resolved):
            return resolved
        if candidate == "curl":
            return resolved
    return None


def run_http_check(curl_path: str, check: HttpCheck, http_version: str) -> bool:
    curl_args = [
        curl_path,
        "--silent",
        "--show-error",
        "--output",
        "/dev/null",
        "--write-out",
        "%{http_code}",
        "--max-time",
        "20",
    ]

    if http_version == "http1.1":
        curl_args.append("--http1.1")
    elif http_version == "http2":
        curl_args.append("--http2")
    elif http_version == "http3":
        curl_args.append("--http3-only")
    else:
        raise ValueError(f"Unsupported HTTP version: {http_version}")

    curl_args.append(check.url)

    try:
        result = subprocess.run(curl_args, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        print("curl is required for edge smoke checks", file=sys.stderr)
        return False

    if result.returncode != 0:
        if http_version == "http3" and "option --http3-only" in result.stderr:
            print(f"[WARN] {check.name} {http_version}: local curl build lacks HTTP/3 support")
            return True
        print(
            f"[FAIL] {check.name} {http_version}: curl exited {result.returncode}: {result.stderr.strip()}",
            file=sys.stderr,
        )
        return False

    try:
        status_code = int(result.stdout.strip())
    except ValueError:
        print(
            f"[FAIL] {check.name} {http_version}: unexpected status output {result.stdout!r}",
            file=sys.stderr,
        )
        return False

    if status_code not in check.expected_codes:
        print(
            f"[FAIL] {check.name} {http_version}: expected {check.expected_codes}, got {status_code}",
            file=sys.stderr,
        )
        return False

    print(f"[PASS] {check.name} {http_version}: {status_code}")
    return True


def run_websocket_check(check: WebSocketCheck) -> bool:
    websocket_key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {check.path} HTTP/1.1\r\n"
        f"Host: {check.host}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {websocket_key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Origin: https://{host}\r\n"
        "\r\n"
    ).replace("{host}", check.host)

    context = ssl.create_default_context()

    try:
        with socket.create_connection((check.host, check.port), timeout=20) as raw_socket:
            with context.wrap_socket(raw_socket, server_hostname=check.host) as tls_socket:
                tls_socket.sendall(request.encode("ascii"))
                response = tls_socket.recv(4096).decode("utf-8", errors="replace")

                accept_source = (
                    f"{websocket_key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11".encode("ascii")
                )
                expected_accept = base64.b64encode(hashlib.sha1(accept_source).digest()).decode("ascii")

                if "101 Switching Protocols" not in response:
                    print(f"[FAIL] {check.name}: missing 101 response", file=sys.stderr)
                    print(response, file=sys.stderr)
                    return False

                if expected_accept not in response:
                    print(f"[FAIL] {check.name}: invalid Sec-WebSocket-Accept", file=sys.stderr)
                    print(response, file=sys.stderr)
                    return False

                if check.expect_substring:
                    frame = tls_socket.recv(4096)
                    payload = decode_text_frame(frame)
                    if check.expect_substring not in payload:
                        print(
                            f"[FAIL] {check.name}: expected payload containing {check.expect_substring!r}, got {payload!r}",
                            file=sys.stderr,
                        )
                        return False
    except OSError as exc:
        print(f"[FAIL] {check.name}: {exc}", file=sys.stderr)
        return False

    print(f"[PASS] {check.name}: websocket handshake succeeded")
    return True


def decode_text_frame(frame: bytes) -> str:
    if len(frame) < 2:
        return ""

    payload_length = frame[1] & 0x7F
    index = 2

    if payload_length == 126:
        if len(frame) < 4:
            return ""
        payload_length = int.from_bytes(frame[index:index + 2], "big")
        index += 2
    elif payload_length == 127:
        if len(frame) < 10:
            return ""
        payload_length = int.from_bytes(frame[index:index + 8], "big")
        index += 8

    masked = bool(frame[1] & 0x80)
    mask = b""
    if masked:
        if len(frame) < index + 4:
            return ""
        mask = frame[index:index + 4]
        index += 4

    if len(frame) < index + payload_length:
        return ""

    payload = bytearray(frame[index:index + payload_length])
    if masked:
        for i in range(payload_length):
            payload[i] ^= mask[i % 4]

    return payload.decode("utf-8", errors="replace")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--include-esphome-canary",
        action="store_true",
        help="Include the ESPHome Traefik canary hostname in the HTTP checks.",
    )
    parser.add_argument(
        "--skip-http3",
        action="store_true",
        help="Skip informational HTTP/3 checks.",
    )
    parser.add_argument(
        "--esphome-websocket-path",
        default="",
        help="Optional ESPHome canary WebSocket path to verify after the HTTP checks.",
    )
    parser.add_argument(
        "--esphome-websocket-contains",
        default="",
        help="Optional substring expected in the first ESPHome WebSocket frame.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    curl_path = resolve_curl_path()
    if curl_path is None:
        parser.error("curl is required")

    print(f"[INFO] Using curl: {curl_path}")

    checks = list(BASELINE_HTTP_CHECKS)
    if args.include_esphome_canary:
        checks.extend(ESPHOME_CANARY_HTTP_CHECKS)

    ok = True

    for check in checks:
        for version in ("http1.1", "http2"):
            ok = run_http_check(curl_path, check, version) and ok
        if not args.skip_http3:
            ok = run_http_check(curl_path, check, "http3") and ok

    for check in WEBSOCKET_CHECKS:
        ok = run_websocket_check(check) and ok

    if args.include_esphome_canary and args.esphome_websocket_path:
        esphome_ws_check = WebSocketCheck(
            name="ESPHome canary WebSocket",
            host="esphome-traefik.ironstone.casa",
            path=args.esphome_websocket_path,
            expect_substring=args.esphome_websocket_contains,
        )
        ok = run_websocket_check(esphome_ws_check) and ok

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
