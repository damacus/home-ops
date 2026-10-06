"""Rule selection must widen coverage without loading duplicate global rules."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]

class RuleNamespaceTests(unittest.TestCase):
    def test_explicit_namespaces_preserve_single_global_database_copy(self) -> None:
        release = yaml.safe_load((ROOT / 'kubernetes/apps/monitoring/victoria-metrics/app/helmrelease.yaml').read_text())
        spec = release['spec']['values']['vmalert']['spec']
        self.assertEqual(spec['ruleNamespaceSelector'], {'matchExpressions': [{'key': 'kubernetes.io/metadata.name', 'operator': 'In', 'values': ['monitoring', 'cert-manager', 'home-automation', 'kube-system']}]})
        self.assertEqual(spec['ruleSelector'], {})
        canonical = yaml.safe_load((ROOT / 'kubernetes/apps/home-automation/home-assistant-db/app/PrometheusRules.yaml').read_text())
        expressions = {r['alert']: ''.join(str(r['expr']).split()) for g in canonical['spec']['groups'] for r in g['rules']}
        self.assertEqual(len(expressions), 6)
        for db in ('immich-db', 'mealie-db', 'med-tracker-db', 'med-tracker-canary-db'):
            duplicate = yaml.safe_load((ROOT / f'kubernetes/apps/home/{db}/app/PrometheusRules.yaml').read_text())
            for group in duplicate['spec']['groups']:
                for rule in group['rules']:
                    self.assertEqual(''.join(str(rule['expr']).split()), expressions[rule['alert']], db)

    @unittest.skipUnless(os.environ.get('VM_CHART_PATH'), 'Requires exact VictoriaMetrics chart')
    def test_rendered_vmalert_has_explicit_namespace_selector(self) -> None:
        release = yaml.safe_load((ROOT / 'kubernetes/apps/monitoring/victoria-metrics/app/helmrelease.yaml').read_text())
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml') as f:
            yaml.safe_dump(release['spec']['values'], f)
            f.flush()
            rendered = subprocess.check_output(['helm', 'template', 'vm', os.environ['VM_CHART_PATH'], '-n', 'monitoring', '-f', f.name], text=True)
        docs = [d for d in yaml.safe_load_all(rendered) if d]
        alert = next(d for d in docs if d['kind'] == 'VMAlert')
        self.assertEqual(alert['spec']['ruleNamespaceSelector'], release['spec']['values']['vmalert']['spec']['ruleNamespaceSelector'])
        self.assertEqual(alert['spec']['ruleSelector'], {})

if __name__ == '__main__':
    unittest.main()
