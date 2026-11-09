#!/usr/bin/env python3
"""Publish validated Spamhaus feeds as a single atomic generation."""
import ipaddress
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
from urllib.request import urlopen

ROOT = Path(os.environ.get("PUBLISH_ROOT", "/data"))
URL = "https://www.spamhaus.org/drop/drop_v{}.json"


def convert(data: bytes, version: int) -> bytes:
    networks = []
    metadata = None
    for line in data.splitlines():
        entry = json.loads(line)
        if entry.get("type") == "metadata":
            if metadata is not None:
                raise ValueError("duplicate feed metadata")
            metadata = entry
            continue
        if entry.get("type") is not None or metadata is not None:
            raise ValueError("unexpected feed record")
        network = ipaddress.ip_network(entry["cidr"], strict=True)
        if network.version != version or not network.is_global:
            raise ValueError("unexpected network in Spamhaus feed")
        if network.prefixlen < (8 if version == 4 else 16):
            raise ValueError("unexpectedly broad Spamhaus network")
        networks.append(str(network))
    if not networks or metadata is None or metadata.get("records") != len(networks):
        raise ValueError("incomplete Spamhaus feed")
    return ("\n".join(networks) + "\n").encode()


def publish() -> None:
    feeds = {}
    for version in (4, 6):
        with urlopen(URL.format(version), timeout=30) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            raise ValueError("feed exceeds size limit")
        feeds[version] = (raw, convert(raw, version))
    ROOT.mkdir(parents=True, exist_ok=True)
    generation = Path(tempfile.mkdtemp(prefix="generation-", dir=ROOT))
    for version, (raw, cidrs) in feeds.items():
        (generation / f"drop_v{version}.json").write_bytes(raw)
        (generation / f"drop_v{version}.txt").write_bytes(cidrs)
    (generation / "metrics.txt").write_text(
        f"spamhaus_last_success_timestamp_seconds {int(time.time())}\n"
    )
    link = ROOT / ".next"
    link.unlink(missing_ok=True)
    link.symlink_to(generation.name, target_is_directory=True)
    os.replace(link, ROOT / "current")
    for old in ROOT.glob("generation-*"):
        if old != generation and old.is_dir() and time.time() - old.stat().st_mtime > 7 * 86400:
            shutil.rmtree(old)


if __name__ == "__main__":
    publish()
