"""Standalone backup retention must not prune unrelated or incomplete data."""
import importlib.util
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import tempfile
import io
import unittest
from unittest.mock import MagicMock, patch

SCRIPT = Path(__file__).resolve().parents[1] / 'kubernetes/apps/database/cloudnative-pg/components/r2-backup/backup.py'
with patch.dict(sys.modules, {'boto3': MagicMock(), 'botocore': MagicMock(), 'botocore.config': MagicMock(), 'boto3.s3': MagicMock(), 'boto3.s3.transfer': MagicMock()}):
    spec = importlib.util.spec_from_file_location('n8n_backup', SCRIPT)
    backup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backup)


class BackupSafetyTests(unittest.TestCase):
    def test_only_expired_complete_generations_are_selected(self) -> None:
        now = datetime(2026, 10, 15, tzinfo=timezone.utc)
        old = now - timedelta(days=8)
        objects = [
            {'Key': backup.PREFIX + 'old/manifest.json', 'LastModified': old},
            {'Key': backup.PREFIX + 'incomplete/backup.tar.gz', 'LastModified': old},
            {'Key': backup.PREFIX + 'recent/manifest.json', 'LastModified': now},
            {'Key': backup.PREFIX + 'boundary/manifest.json', 'LastModified': now - timedelta(days=7)},
            {'Key': 'other-database/old/manifest.json', 'LastModified': old},
        ]
        self.assertEqual(backup.expired_keys(objects, now), [backup.PREFIX + 'old/manifest.json'])

    def test_unverified_capture_cannot_upload_or_expire_backups(self) -> None:
        with patch.object(backup, 'Path') as path, patch.object(backup.boto3, 'client') as client:
            path.return_value.is_file.return_value = False
            with self.assertRaisesRegex(RuntimeError, 'verified base backup'):
                backup.main()
            client.assert_not_called()

    def test_corrupt_remote_archive_cannot_publish_or_prune(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / 'base').mkdir()
            (work / 'base' / 'PG_VERSION').write_text('18')
            (work / 'verified').touch()
            client = MagicMock()
            client.download_file.side_effect = lambda bucket, key, filename, **kwargs: Path(filename).write_bytes(b'corrupt')
            with patch.object(backup, 'Path', side_effect=lambda value: work / value.removeprefix('/work/')), \
                    patch.object(backup.boto3, 'client', return_value=client), \
                    patch.dict(backup.os.environ, {'R2_ENDPOINT': 'https://example.invalid'}):
                with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                    backup.main()
            client.put_object.assert_not_called()
            client.delete_object.assert_not_called()
            client.get_paginator.assert_not_called()


if __name__ == '__main__':
    unittest.main()
