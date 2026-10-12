#!/usr/bin/env python3
"""Apply a reviewed gateway key policy without printing credentials.

Keys are generated in 1Password first. Inject LITELLM_MASTER_KEY and
LITELLM_CLIENT_KEY with `op run`; do not pass secrets as command arguments.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

POLICIES = Path(__file__).resolve().parents[1] / "kubernetes/apps/dev/litellm/keys.json"


def request(base: str, master: str, method: str, path: str, data: dict[str, Any] | None = None) -> dict[str, Any]:
    body = json.dumps(data).encode() if data is not None else None
    req = Request(base.rstrip("/") + path, data=body, method=method,
                  headers={"Authorization": f"Bearer {master}", "Content-Type": "application/json"})
    with urlopen(req, timeout=30) as response:
        return json.load(response)


def reconcile(base: str, master: str, key: str, policy: dict[str, Any]) -> str:
    # Query with the hash, so reverse-proxy URLs cannot contain the credential.
    hashed = hashlib.sha256(key.encode()).hexdigest()
    try:
        request(base, master, "GET", "/key/info?" + urlencode({"key": hashed}))
    except HTTPError as error:
        error.close()
        if error.code != 404:
            raise
        request(base, master, "POST", "/key/generate", {**policy, "key": key})
        return "created"
    # No spend, reset timestamp or duration is sent: reapplying must not renew a budget.
    update = {k: v for k, v in policy.items() if k != "key_type"}
    request(base, master, "POST", "/key/update", {**update, "key": key})
    return "updated"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    policies = json.loads(POLICIES.read_text())
    parser.add_argument("client", choices=policies)
    parser.add_argument("--url", default="https://litellm.ironstone.casa")
    parser.add_argument("--apply", action="store_true", help="Write key policy after rollout approval")
    args = parser.parse_args()
    if not args.apply:
        print(json.dumps(policies[args.client], indent=2))
        return 0
    parsed = urlparse(args.url)
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"}):
        parser.error("Use HTTPS or a localhost port-forward")
    master, key = os.environ.get("LITELLM_MASTER_KEY", ""), os.environ.get("LITELLM_CLIENT_KEY", "")
    if not master.startswith("sk-") or not key.startswith("sk-") or master == key:
        parser.error("Inject distinct sk- master and client keys through the environment")
    try:
        result = reconcile(args.url, master, key, policies[args.client])
    except HTTPError as error:
        print(f"Key operation failed: HTTP {error.code}; response suppressed")
        return 1
    except (URLError, TimeoutError):
        print("Gateway unavailable; key state is unconfirmed")
        return 1
    print(f"{args.client}: {result}; credential suppressed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
