"""Upload verified standalone PostgreSQL backups and expire complete generations."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
from datetime import datetime, timedelta, timezone
import tarfile
import uuid
import boto3
from botocore.config import Config
from boto3.s3.transfer import TransferConfig

PREFIX = os.environ.get("BACKUP_PREFIX", "n8n-r2-pilot/physical/")

def expired_keys(objects: list[dict], now: datetime, days: int = 7) -> list[str]:
    cutoff = now - timedelta(days=days)
    return [o["Key"] for o in objects if o["Key"].startswith(PREFIX)
            and o["Key"].endswith("/manifest.json") and o["LastModified"] < cutoff]

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def main() -> None:
    root = Path("/work/base")
    # This marker is written only after pg_verifybackup succeeds.
    if not Path("/work/verified").is_file():
        raise RuntimeError("Refusing upload or retention without a verified base backup")
    archive = Path("/work/backup.tar.gz")
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(root, arcname="data")
    digest = sha256(archive)
    s3 = boto3.client("s3", endpoint_url=os.environ["R2_ENDPOINT"], region_name="auto",
        config=Config(signature_version="s3v4", connect_timeout=10, read_timeout=180,
                      retries={"mode": "standard", "max_attempts": 5}, request_checksum_calculation="when_required",
                      response_checksum_validation="when_required"))
    bucket = "cnpg"
    generation = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex
    base = PREFIX + generation + "/"
    key = base + "backup.tar.gz"
    transfer = TransferConfig(max_concurrency=2, num_download_attempts=5)
    s3.upload_file(str(archive), bucket, key, ExtraArgs={"Metadata": {"sha256": digest}}, Config=transfer)
    # Verify persisted bytes before publishing the completion manifest.
    downloaded = Path("/work/remote-verification.tar.gz")
    s3.download_file(bucket, key, str(downloaded), Config=transfer)
    if sha256(downloaded) != digest:
        raise RuntimeError("R2 archive checksum mismatch; no completion or retention")
    downloaded.unlink()
    manifest = {"generation": generation, "archive": key, "sha256": digest,
                "bytes": archive.stat().st_size, "postgres_major": 18,
                "wal": "included by pg_basebackup --wal-method=stream"}
    s3.put_object(Bucket=bucket, Key=base + "manifest.json", Body=json.dumps(manifest).encode(),
                  ContentType="application/json")
    objects = [o for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=PREFIX)
               for o in page.get("Contents", [])]
    # Expire only this job's completed generations, never arbitrary bucket objects.
    for old in expired_keys(objects, datetime.now(timezone.utc)):
        old_base = old.removesuffix("manifest.json")
        s3.delete_object(Bucket=bucket, Key=old_base + "backup.tar.gz")
        s3.delete_object(Bucket=bucket, Key=old)
    print(json.dumps({"completed": True, **manifest}), flush=True)

if __name__ == "__main__":
    main()
