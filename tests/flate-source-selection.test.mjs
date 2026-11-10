import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';

const helper = resolve('scripts/flate-snapshots.mjs');
const entry = readFileSync('scripts/flate-entry.yaml');

test('diff renders the candidate source with worktree metadata and rejects missing manifests', () => {
  const repo = mkdtempSync(join(tmpdir(), 'flate-source-test-'));
  const put = (path, body) => {
    mkdirSync(dirname(join(repo, path)), { recursive: true });
    writeFileSync(join(repo, path), typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  };
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const commit = subject => {
    git('add', '--all');
    git('-c', 'user.name=Flate Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', subject);
  };
  const pkg = resources => ({ apiVersion: 'kustomize.config.k8s.io/v1beta1', kind: 'Kustomization', resources });
  const ks = (name, path) => ({
    apiVersion: 'kustomize.toolkit.fluxcd.io/v1', kind: 'Kustomization',
    metadata: { name, namespace: 'flux-system' },
    spec: { interval: '1m', path, sourceRef: { kind: 'GitRepository', name: 'home-kubernetes' } },
  });
  const cm = (name, value) => ({ apiVersion: 'v1', kind: 'ConfigMap', metadata: { name, namespace: 'default' }, data: { value } });
  try {
    git('init', '-q', '--initial-branch=main');
    git('remote', 'add', 'origin', 'https://fixture.invalid/home-ops');
    put('scripts/flate-entry.yaml', entry);
    put('kubernetes/flux/config/kustomization.yaml', pkg(['source.yaml']));
    put('kubernetes/flux/config/source.yaml', {
      apiVersion: 'source.toolkit.fluxcd.io/v1', kind: 'GitRepository',
      metadata: { name: 'home-kubernetes', namespace: 'flux-system' },
      spec: { interval: '1m', timeout: '1s', url: 'https://fixture.invalid/home-ops', ref: { branch: 'main' } },
    });
    put('kubernetes/flux/repositories/kustomization.yaml', pkg([]));
    put('kubernetes/bootstrap/flux/kustomization.yaml', pkg([]));
    put('kubernetes/flux/cluster/ks.yaml', ks('apps', './kubernetes/apps'));
    put('kubernetes/apps/kustomization.yaml', pkg(['existing/ks.yaml']));
    put('kubernetes/apps/existing/ks.yaml', ks('existing', './kubernetes/apps/existing/app'));
    put('kubernetes/apps/existing/app/kustomization.yaml', pkg(['config.yaml']));
    put('kubernetes/apps/existing/app/config.yaml', cm('existing', 'before'));
    commit('test: baseline');
    const base = git('rev-parse', 'HEAD');
    put('scripts/flate-entry.yaml', Buffer.concat([entry, Buffer.from('  - flux/extra\n')]));
    put('kubernetes/flux/extra/kustomization.yaml', pkg(['config.yaml']));
    put('kubernetes/flux/extra/config.yaml', cm('entry-only', 'new'));
    put('kubernetes/apps/kustomization.yaml', pkg(['existing/ks.yaml', 'candidate/ks.yaml']));
    put('kubernetes/apps/existing/app/config.yaml', cm('existing', 'after'));
    put('kubernetes/apps/candidate/ks.yaml', ks('candidate', './kubernetes/apps/candidate/app'));
    put('kubernetes/apps/candidate/app/kustomization.yaml', pkg(['config.yaml']));
    put('kubernetes/apps/candidate/app/config.yaml', cm('candidate-only', 'new'));
    commit('test: candidate');
    git('config', 'core.repositoryformatversion', '1');
    git('config', 'extensions.worktreeConfig', 'true');
    const run = (args = ['diff', '--base', base, '--path', 'kubernetes', '-o', 'json']) => spawnSync(process.execPath, [helper, ...args], {
      cwd: repo, encoding: 'utf8', env: { ...process.env, FLATE_BASE: '', FLATE_SELF_URL: 'https://fixture.invalid/home-ops' },
    });
    const valid = run();
    assert.equal(valid.status, 0, valid.stderr);
    const parsed = JSON.parse(valid.stdout);
    const changes = (Array.isArray(parsed) ? parsed : [parsed]).flatMap(result => result.changes);
    assert.ok(changes.some(change => change.kind === 'ConfigMap' && change.name === 'candidate-only' && change.status === 'added'));
    assert.ok(changes.some(change => change.kind === 'ConfigMap' && change.name === 'entry-only' && change.status === 'added'));
    assert.ok(changes.some(change => change.kind === 'ConfigMap' && change.name === 'existing' && change.old?.data.value === 'before' && change.new?.data.value === 'after'), JSON.stringify(changes));
    git('remote', 'remove', 'origin');
    for (const mode of ['test', 'build']) {
      const local = run([mode, '--path', 'kubernetes']);
      assert.equal(local.status, 0, local.stderr);
    }
    const baseline = mkdtempSync(join(tmpdir(), 'flate-independent-base-'));
    try {
      git('worktree', 'add', '--detach', baseline, base);
      const independent = run(['diff', '--path-orig', join(baseline, 'kubernetes'), '--path', 'kubernetes', '-o', 'json']);
      assert.equal(independent.status, 0, independent.stderr);
    } finally {
      git('worktree', 'remove', '--force', baseline);
    }
    put('kubernetes/apps/candidate/ks.yaml', ks('candidate', './kubernetes/apps/missing/app'));
    commit('test: missing manifest');
    const invalid = run();
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, /missing\/app|not a directory|does not exist/);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});
