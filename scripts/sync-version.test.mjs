import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = fileURLToPath(new URL('./sync-version.mjs', import.meta.url));
const cli = fileURLToPath(new URL('../node_modules/@changesets/cli/bin.js', import.meta.url));
const changesetConfig = readFileSync(new URL('../.changeset/config.json', import.meta.url), 'utf8');
const directories = ['.', 'lilo-ui', 'Lilo/Extensions/bridge-src'];
const configPath = 'Xcode/Configs/Base.xcconfig';
const config = 'SWIFT_VERSION = 6.0\nCURRENT_PROJECT_VERSION = 5\nMARKETING_VERSION = 0.1.4\n';

function fixture(t, version = '0.1.4') {
  const root = mkdtempSync(join(tmpdir(), 'lilo-version-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const write = (path, content) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), content);
  };
  const json = (path, data) => write(path, `${JSON.stringify(data, null, 2)}\n`);
  for (const directory of directories) {
    const name = directory === '.' ? 'lilo' : directory;
    json(`${directory}/package.json`, { name, private: true, version: directory === '.' ? version : '0.1.4' });
    json(`${directory}/package-lock.json`, {
      name, version: '0.1.4', lockfileVersion: 3,
      packages: { '': { name, version: '0.1.4' }, 'node_modules/example': { version: '1.2.3' } },
    });
  }
  write(configPath, config);
  return {
    root,
    read: (path) => readFileSync(join(root, path), 'utf8'),
    run: (...args) => spawnSync(process.execPath, [script, ...args], { cwd: root, encoding: 'utf8' }),
    write,
  };
}

for (const version of ['0.1.5', '0.2.0', '1.0.0']) {
  test(`syncs ${version} and increments the Sparkle build number once`, (t) => {
    const files = fixture(t, version);
    const result = files.run();
    assert.equal(result.status, 0, result.stderr);
    const expected = config.replace('= 5', '= 6').replace('0.1.4', version);
    assert.equal(files.read(configPath), expected);
    for (const directory of directories) {
      assert.equal(JSON.parse(files.read(`${directory}/package.json`)).version, version);
      const lock = JSON.parse(files.read(`${directory}/package-lock.json`));
      assert.equal(lock.version, version);
      assert.equal(lock.packages[''].version, version);
      assert.equal(lock.packages['node_modules/example'].version, '1.2.3');
    }
    assert.equal(files.run().status, 0);
    assert.equal(files.read(configPath), expected);
    assert.equal(files.run('--check').status, 0);
  });
}

test('a release without a version change leaves the build number alone', (t) => {
  const files = fixture(t);
  assert.equal(files.run().status, 0);
  assert.equal(files.read(configPath), config);
});

test('check rejects stale native and npm versions without writing files', (t) => {
  const files = fixture(t, '0.1.5');
  assert.notEqual(files.run('--check').status, 0);
  assert.equal(files.read(configPath), config);
  assert.equal(files.run().status, 0);
  const staleLock = files.read('lilo-ui/package-lock.json').replaceAll('0.1.5', '0.1.4');
  files.write('lilo-ui/package-lock.json', staleLock);
  assert.notEqual(files.run('--check').status, 0);
  assert.equal(files.read('lilo-ui/package-lock.json'), staleLock);
});

test('Changesets status accepts a consumed release and still rejects invalid notes', (t) => {
  const files = fixture(t);
  files.write('.changeset/config.json', changesetConfig);
  const git = (...args) => {
    const result = spawnSync('git', args, { cwd: files.root, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  };
  git('init', '-q', '-b', 'release-test');
  git('add', '.');
  git('-c', 'user.name=Release test', '-c', 'user.email=release-test@example.com', 'commit', '-qm', 'test: seed release');
  const changeset = (...args) => spawnSync(process.execPath, [cli, ...args], { cwd: files.root, encoding: 'utf8' });
  assert.equal(changeset('status').status, 0);
  files.write('.changeset/release.md', '---\n"lilo": patch\n---\n\nFix tab switching.\n');
  const status = changeset('status');
  assert.equal(status.status, 0, status.stderr);
  assert.match(status.stdout, /lilo/);
  const version = changeset('version');
  assert.equal(version.status, 0, version.stderr);
  assert.equal(files.run().status, 0);
  assert.equal(JSON.parse(files.read('package.json')).version, '0.1.5');
  assert.match(files.read('CHANGELOG.md'), /Fix tab switching\./);
  const released = changeset('status');
  assert.equal(released.status, 0, released.stderr);
  files.write('.changeset/invalid.md', '---\n"missing-package": patch\n---\n\nInvalid note.\n');
  assert.notEqual(changeset('status').status, 0);
});
