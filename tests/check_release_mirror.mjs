// Exercise the installed Renovate engine against real repository manifests.
// Run with: node tests/check_release_mirror.mjs --renovate-dir <npm package path>
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { mkdtemp, mkdir, readFile, writeFile, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const argument = process.argv.indexOf('--renovate-dir');
const renovateDir = argument < 0
  ? dirname(createRequire(import.meta.url).resolve('renovate/package.json'))
  : resolve(process.argv[argument + 1]);
const require = createRequire(join(renovateDir, 'package.json'));
const JSON5 = require('json5');
const config = JSON5.parse(await readFile(join(root, '.github/renovate.json5'), 'utf8'));
assert(config.customDatasources?.['release-mirror'], 'Release Mirror must be configured');
const mappings = config.packageRules.filter(rule => rule.overrideDatasource === 'custom.release-mirror');
assert(mappings.length > 0, 'First-party images must be redirected to Release Mirror');
const aliases = new Set(mappings.map(rule => rule.overridePackageName));
const paths = [
  'kubernetes/apps/dev/ironbridge/app/deployment.yaml',
  'kubernetes/apps/dev/northbot/app/deployment.yaml',
  'kubernetes/apps/home/ledger/app/resources.yaml',
  'kubernetes/apps/home/med-tracker/app/helmrelease.yaml',
  'kubernetes/apps/default/unifi-release-announcer/app/HelmRelease.yaml',
  'kubernetes/apps/kube-system/reflector/app/helmrelease.yaml',
  'kubernetes/apps/medtracker-canary/app/workloads.yaml',
  'kubernetes/apps/medtracker-canary/app/reset.yaml',
];
const digest = `sha256:${'e'.repeat(64)}`;
const {applyPackageRules} = await import(pathToFileURL(join(renovateDir, 'dist/util/package-rules/index.js')));
const {extractPackageFile} = await import(pathToFileURL(join(renovateDir, 'dist/modules/manager/index.js')));
const currentReleases = new Map();
for (const path of paths) {
  const content = await readFile(join(root, path), 'utf8');
  for (const manager of ['kubernetes', 'helm-values', 'flux']) {
    const extracted = await extractPackageFile(manager, content, path, {});
    for (const dep of extracted?.deps ?? []) {
      const effective = await applyPackageRules({...dep, manager, packageFile: path, packageRules: config.packageRules});
      if (effective.datasource === 'custom.release-mirror' && dep.currentValue !== 'main') {
        const releases = currentReleases.get(effective.packageName) ?? [];
        if (!releases.some(release => release.version === dep.currentValue)) {
          releases.push({version: dep.currentValue, ...(dep.currentDigest ? {digest: dep.currentDigest} : {})});
        }
        currentReleases.set(effective.packageName, releases);
      }
    }
  }
}
const requests = [];
const server = createServer((request, response) => {
  requests.push(request.url);
  const alias = /^\/api\/v1\/services\/([^/]+)\/renovate$/.exec(request.url)?.[1];
  if (!aliases.has(alias)) {
    response.writeHead(404).end();
    return;
  }
  response.setHeader('Content-Type', 'application/json');
  response.end(JSON.stringify({releases: [
    ...(currentReleases.get(alias) ?? []),
    {version: 'main', digest},
    {version: '99.0.0', digest},
  ]}));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const scratch = await mkdtemp(join(tmpdir(), 'home-ops-release-mirror-'));
try {
  for (const path of paths) {
    await mkdir(dirname(join(scratch, path)), {recursive: true});
    await cp(join(root, path), join(scratch, path));
  }
  // A third-party image proves the mapping is package-scoped, not registry-wide.
  await writeFile(join(scratch, 'kubernetes/control.yaml'),
    'apiVersion: v1\nkind: Pod\nmetadata: {name: control}\nspec:\n  containers:\n    - name: public\n      image: ghcr.io/cloudnative-pg/postgresql:18\n');
  const feed = `http://127.0.0.1:${server.address().port}/api/v1/services/{{packageName}}/renovate`;
  const patterns = ['/kubernetes/.*\\.ya?ml$/'];
  const fixtureConfig = {
    customDatasources: {'release-mirror': {...config.customDatasources['release-mirror'], defaultRegistryUrlTemplate: feed}},
    enabledManagers: ['kubernetes', 'helm-values', 'flux'],
    kubernetes: {managerFilePatterns: patterns},
    'helm-values': {managerFilePatterns: patterns},
    flux: {managerFilePatterns: patterns},
    packageRules: [
      ...config.packageRules,
      // Isolate lookups from unrelated charts/images; retain real package mappings.
      {matchPackageNames: ['*'], enabled: false},
      {matchDatasources: ['custom.release-mirror'], enabled: true},
    ],
  };
  await writeFile(join(scratch, 'renovate.json'), JSON.stringify(fixtureConfig));
  execFileSync('git', ['init', '--quiet', scratch]);
  execFileSync('git', ['-C', scratch, 'add', '.']);
  const child = spawn(process.execPath, [join(renovateDir, 'dist/renovate.js'),
    '--platform=local', '--onboarding=false', '--require-config=required', '--dry-run=lookup'], {
    cwd: scratch,
    env: {...process.env, LOG_LEVEL: 'debug', LOG_FORMAT: 'json',
      RENOVATE_X_ALLOW_LOCAL_HTTP: 'true', RENOVATE_INTERNAL_HOST_ACCESS: 'block',
      RENOVATE_HOST_RULES: JSON.stringify([{matchHost: '127.0.0.1', allowInternal: true}]),
      RENOVATE_GIT_AUTHOR: 'Fixture <fixture@example.test>'},
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  const timer = setTimeout(() => child.kill('SIGTERM'), 60_000);
  const code = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
  });
  clearTimeout(timer);
  const events = output.split('\n').flatMap(line => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
  assert.equal(code, 0, events.filter(event => event.level >= 40).map(event => event.msg).join('\n'));
  const packages = events.find(event => event.msg === 'packageFiles with updates')?.config;
  assert(packages, 'Renovate must finish extraction and lookup');
  const managed = [];
  for (const [manager, files] of Object.entries(packages)) {
    for (const file of files) {
      for (const [depIndex, dep] of file.deps.entries()) {
        const effective = await applyPackageRules({...dep, manager, packageFile: file.packageFile, packageRules: config.packageRules});
        if (aliases.has(effective.packageName)) managed.push({...effective, depIndex});
      }
    }
  }
  assert.deepEqual(new Set(managed.map(dep => dep.packageName)), aliases, 'Every managed package must be extracted from its actual layout');
  for (const dep of managed) {
    assert.equal(dep.datasource, 'custom.release-mirror');
    assert.equal(dep.automerge, false, 'Internal images must retain manual deployment review');
    assert(dep.updates?.some(update => update.newDigest === digest), `${dep.manager}: ${dep.depName} must get a catalogue digest`);
    if (dep.currentValue === 'main') {
      assert(dep.updates.every(update => update.newValue === 'main'), 'Moving tags must not switch to numbered releases');
    } else {
      assert(dep.updates.some(update => update.newValue === '99.0.0'), 'Numbered tags must receive version and digest updates');
    }
  }
  assert(packages.kubernetes.some(file => file.deps.some(dep => dep.depName === 'ghcr.io/cloudnative-pg/postgresql' && dep.datasource === 'docker')),
    'Unmanaged images must retain the Docker datasource');
  assert.deepEqual(new Set(requests.map(url => url.split('/')[4])), aliases, 'Only catalogue aliases may be requested');
  assert(!events.some(event => event.msg?.includes('getManifestResponse(')), 'No Docker registry lookup may run for managed images');
  const frozen = Object.values(packages).flat().flatMap(file => file.deps)
    .filter(dep => /med-tracker-loco|home-ops-medtracker-canary-reset/.test(dep.depName));
  assert(frozen.length > 0 && frozen.every(dep => dep.skipReason === 'disabled' && !dep.updates?.length), 'Checked canary images must remain pinned');
  for (const dep of frozen) {
    const effective = await applyPackageRules({...dep, packageRules: config.packageRules});
    assert.equal(effective.enabled, false, 'The repository rules must explicitly disable checked canary updates');
  }

  // Use Renovate's actual replacement engine too: test anchors, repeated
  // containers, tag-only references and multi-document manifests.
  const {GlobalConfig} = await import(pathToFileURL(join(renovateDir, 'dist/config/global.js')));
  GlobalConfig.set({localDir: scratch});
  const {doAutoReplace} = await import(pathToFileURL(join(renovateDir, 'dist/workers/repository/update/branch/auto-replace.js')));
  for (const dep of managed) {
    const content = await readFile(join(scratch, dep.packageFile), 'utf8');
    const update = dep.updates.find(update => update.newDigest === digest);
    const changed = await doAutoReplace({...dep, ...update, autoReplaceGlobalMatch: true}, content, false);
    assert(changed?.includes(digest), `Renovate must replace ${dep.packageFile}`);
    assert(changed.includes(dep.depName), 'Replacement must preserve the private image repository');
  }
  console.log(`Release Mirror contract passed: ${aliases.size} packages; native extraction, lookup and replacement; no Docker lookups; fixed canary pins preserved.`);
} finally {
  await new Promise(resolve => server.close(resolve));
  await rm(scratch, {recursive: true, force: true});
}
