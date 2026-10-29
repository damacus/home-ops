#!/usr/bin/env python3
"""Preview or apply Mealie provider cutover through its supported API.

Inject MEALIE_TOKEN and LITELLM_CLIENT_KEY from 1Password. No provider keys,
headers or request parameters are printed or saved. Back up the database first.
"""
from __future__ import annotations

import argparse
import json
import os
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

MODEL_MAP = {"gpt-5": "gpt-6.1-terra", "gpt-4o": "gpt-6.1-sol",
             "whisper-1": "gpt-4o-mini-transcribe"}

def provider_update(provider: dict[str, Any], key: str, endpoint: str) -> dict[str, Any]:
    # Custom authentication could override the gateway key; stop for review.
    if provider.get("requestHeaders") or provider.get("requestParams"):
        raise ValueError("Custom provider headers or parameters require review before cutover")
    return {"name": provider["name"], "model": MODEL_MAP.get(provider["model"], provider["model"]),
            "timeout": provider["timeout"], "baseUrl": endpoint, "apiKey": key,
            "requestHeaders": {}, "requestParams": {}}


def call(base: str, token: str, method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    req = Request(base.rstrip("/") + path, method=method,
                  headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
                  data=json.dumps(payload).encode() if payload is not None else None)
    with urlopen(req, timeout=30) as response:
        return json.load(response)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    token = os.environ.get("MEALIE_TOKEN", "")
    key = os.environ.get("LITELLM_CLIENT_KEY", "")
    if not token or (args.apply and not key.startswith("sk-")):
        parser.error("Inject MEALIE_TOKEN and, for writes, LITELLM_CLIENT_KEY")
    base = "https://mealie.damacus.io"
    path = "/api/groups/ai-providers"
    try:
        settings = call(base, token, "GET", path + "/settings")
        updates = []
        for item in settings["providers"]:
            provider = call(base, token, "GET", path + "/providers/" + item["id"])
            updates.append((item["id"], provider_update(provider, key, "http://litellm.dev.svc.cluster.local:4000/v1")))
        # Validate every provider before the first write. Selection IDs stay intact.
        for identifier, payload in updates:
            if args.apply:
                call(base, token, "PUT", path + "/providers/" + identifier, payload)
                saved = call(base, token, "GET", path + "/providers/" + identifier)
                if saved["model"] != payload["model"] or saved["baseUrl"] != payload["baseUrl"]:
                    raise ValueError("Provider read-back did not match; stop and inspect")
            print(f"{identifier}: {'updated' if args.apply else 'planned'} ({payload['model']})")
    except HTTPError as error:
        print(f"Mealie request failed: HTTP {error.code}; response suppressed. Check partial progress before retrying.")
        return 1
    except (URLError, TimeoutError, ValueError) as error:
        print(str(error) if isinstance(error, ValueError) else "Mealie unavailable; check partial progress before retrying")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
