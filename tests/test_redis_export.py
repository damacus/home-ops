"""Run the migration Job's shell with fault-injected export/validation tools."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
JOB = ROOT / 'kubernetes/apps/database/redis/migration/export-job.yaml'


class ExportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix='redis-export-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data = self.root / 'data'
        self.data.mkdir()
        tools = self.root / 'bin'
        tools.mkdir()
        export = tools / 'redis-cli'
        export.write_text('''#!/bin/bash
while [[ "$1" != "--rdb" ]]; do shift; done
printf 'snapshot' > "$2"
[[ "$EXPORT_FAIL" != 1 ]]
''')
        validate = tools / 'redis-check-rdb'
        validate.write_text('''#!/bin/bash
if [[ "$RACE_FINAL" == 1 ]]; then printf 'other-valid-snapshot' > "$DATA_ROOT/dump.rdb"; fi
[[ "$VALIDATION_FAIL" != 1 ]]
''')
        for script in (export, validate):
            script.chmod(0o755)
        self.environment = {**os.environ, 'PATH': f'{tools}:{os.environ["PATH"]}', 'DATA_ROOT': str(self.data)}
        self.script = yaml.safe_load(JOB.read_text())['spec']['template']['spec']['containers'][0]['args'][0].replace('/data', str(self.data))

    def execute(self, **faults: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(['/bin/bash', '-ec', self.script], env={**self.environment, **faults}, capture_output=True, text=True, timeout=10)

    def test_failed_export_can_retry(self) -> None:
        self.assertNotEqual(self.execute(EXPORT_FAIL='1').returncode, 0)
        self.assertEqual(list(self.data.iterdir()), [])
        self.assertEqual(self.execute().returncode, 0)
        self.assertEqual((self.data / 'dump.rdb').read_text(), 'snapshot')

    def test_failed_validation_can_retry(self) -> None:
        self.assertNotEqual(self.execute(VALIDATION_FAIL='1').returncode, 0)
        self.assertEqual(list(self.data.iterdir()), [])
        self.assertEqual(self.execute().returncode, 0)

    def test_preserves_existing_snapshot(self) -> None:
        final = self.data / 'dump.rdb'
        final.write_text('existing')
        self.assertNotEqual(self.execute().returncode, 0)
        self.assertEqual(final.read_text(), 'existing')

    def test_preserves_existing_aof(self) -> None:
        (self.data / 'appendonlydir').mkdir()
        self.assertNotEqual(self.execute().returncode, 0)
        self.assertFalse((self.data / 'dump.rdb').exists())

    def test_does_not_overwrite_concurrent_publication(self) -> None:
        self.assertNotEqual(self.execute(RACE_FINAL='1').returncode, 0)
        self.assertEqual((self.data / 'dump.rdb').read_text(), 'other-valid-snapshot')
        self.assertEqual(len(list(self.data.iterdir())), 1)

    def test_cleans_only_own_temporary_file(self) -> None:
        other = self.data / '.redis-export-other'
        other.write_text('preserve')
        self.assertNotEqual(self.execute(EXPORT_FAIL='1').returncode, 0)
        self.assertEqual(list(self.data.iterdir()), [other])


if __name__ == '__main__':
    unittest.main()
