import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';

const args = process.argv.slice(2);
const mode = args.shift();
const take = name => {
  const index = args.indexOf(name);
  if (index < 0) return undefined;
  if (!args[index + 1]) throw new Error(`${name} requires a value`);
  return args.splice(index, 2)[1];
};
const git = (cwd, command, options = {}) => {
  try {
    return execFileSync('git', command, { cwd, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], ...options });
  } catch (error) {
    throw new Error(`Git ${command[0]} failed (exit ${error.status ?? 1})`);
  }
};
const inside = (root, path) => {
  const result = relative(root, path);
  if (isAbsolute(result) || result === '..' || result.startsWith(`..${sep}`)) throw new Error('Render path must be inside its checkout');
  return result;
};
const temporary = mkdtempSync(join(tmpdir(), 'home-ops-flate-'));
try {
  if (!['test', 'build', 'diff'].includes(mode)) throw new Error('Expected test, build or diff');
  const root = git(process.cwd(), ['rev-parse', '--show-toplevel']).trim();
  const scan = inside(root, realpathSync(resolve(take('--path') || process.env.FLATE_PATH || 'kubernetes')));
  const baseRef = take('--base') || process.env.FLATE_BASE || 'origin/main';
  const original = take('--path-orig');
  const pathOrig = original ? realpathSync(resolve(original)) : undefined;
  const head = git(root, ['rev-parse', 'HEAD']).trim();
  const entry = readFileSync(join(root, 'scripts/flate-entry.yaml'));
  const snapshot = (name, source, revision, working) => {
    const directory = join(temporary, name);
    mkdirSync(directory);
    git(directory, ['init', '--quiet', '--initial-branch=main']);
    git(directory, ['fetch', '--quiet', '--no-tags', '--depth=1', source, revision]);
    git(directory, ['checkout', '--quiet', '--detach', 'FETCH_HEAD']);
    const remotes = git(source, ['remote']).trim().split(/\s+/);
    const sourceURL = remotes.includes('origin')
      ? git(source, ['remote', 'get-url', 'origin']).trim()
      : process.env.FLATE_SELF_URL || 'https://github.com/damacus/home-ops';
    git(directory, ['remote', 'add', 'origin', sourceURL]);
    git(directory, ['update-ref', 'refs/heads/main', revision]);
    if (working) {
      const patch = git(source, ['diff', '--binary', 'HEAD']);
      if (patch) git(directory, ['apply', '--binary', '--whitespace=nowarn', '-'], { input: patch });
      for (const file of git(source, ['ls-files', '--others', '--exclude-standard', '-z']).split('\0').filter(Boolean)) {
        const target = join(directory, file);
        mkdirSync(dirname(target), { recursive: true });
        cpSync(join(source, file), target, { recursive: true, dereference: false });
      }
    }
    const rootEntry = join(directory, 'kubernetes/kustomization.yaml');
    const snapshotEntry = join(directory, 'scripts/flate-entry.yaml');
    if (!existsSync(rootEntry)) writeFileSync(rootEntry, existsSync(snapshotEntry) ? readFileSync(snapshotEntry) : entry);
    return directory;
  };
  const current = snapshot('current', root, head, true);
  const command = [mode, 'all', '--no-progress', '--path', join(current, scan)];
  if (mode === 'diff') {
    const source = pathOrig ? git(resolve(pathOrig), ['rev-parse', '--show-toplevel']).trim() : root;
    const revision = git(source, ['rev-parse', pathOrig ? 'HEAD' : baseRef]).trim();
    const baseline = snapshot('base', source, revision, Boolean(pathOrig));
    const baselineScan = pathOrig ? inside(source, resolve(pathOrig)) : scan;
    command.push('--path-orig', join(baseline, baselineScan));
    process.stderr.write(`Flate source snapshots: ${revision.slice(0, 12)} -> ${head.slice(0, 12)}\n`);
  }
  const env = { ...process.env, FLATE_BASE: '', FLATE_PATH: '' };
  const result = spawnSync(process.env.FLATE_BINARY || 'flate', [...command, ...args], { cwd: current, env, stdio: 'inherit' });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
