// Usage: node scripts/ext-e2e-passwords.mjs <vaultwarden binary> <its 127.0.0.1 certificate>. Exits non-zero when a phase fails.
// The certificate, beside its key.pem, is what `make ext-e2e-passwords-trust` had the keychain trust; Node trusts it through
// NODE_EXTRA_CA_CERTS.
// Bitwarden against a local Vaultwarden, in two test processes on one data folder: the first signs in, fills and saves;
// the second relaunches on a changed prelude, as a Lilo update does, and checks the worker runs it (WEBKIT-GAPS gap 113).
import { spawn, spawnSync } from 'node:child_process';
import { createCipheriv, createHmac, generateKeyPairSync, pbkdf2Sync, randomBytes, randomUUID } from 'node:crypto';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

const root = join(import.meta.dirname, '..');
const [vaultwarden, certificate] = process.argv.slice(2);
const out = join(root, '.derived.noindex/ext-e2e-passwords');
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

// Signed and identified as make's test targets do (Makefile, TEST), as ext-smoke.mjs builds.
const team = process.env.LILO_DEBUG_TEAM_ID || process.env.LILO_TEAM_ID;
const identity = team ? process.env.LILO_DEBUG_CODE_SIGN_IDENTITY || 'Apple Development' : '-';
const signing = team ? [`DEVELOPMENT_TEAM=${team}`, `CODE_SIGN_IDENTITY=${identity}`, 'CODE_SIGN_STYLE=Manual'] : [];
const xcodebuild = ['-project', 'Lilo.xcodeproj', '-scheme', 'Lilo', '-configuration', 'Debug', '-destination', 'platform=macOS',
  '-derivedDataPath', join(root, '.derived.noindex/xcode'), 'LILO_BUNDLE_ID_SUFFIX=.tests', ...signing];
const build = spawnSync('xcodebuild', ['build-for-testing', ...xcodebuild, '-quiet'], { cwd: root, stdio: 'inherit' });
if (build.status !== 0) process.exit(build.status ?? 1);

const port = await new Promise((resolve) => {
  const probe = createServer().listen(0, '127.0.0.1', () => {
    const { port: free } = probe.address();
    probe.close(() => resolve(free));
  });
});
const server = `https://127.0.0.1:${port}`;
// In the temporary folder, as the agent socket inside the data folder must fit a socket path.
const work = mkdtempSync(join(tmpdir(), 'lilo-e2e-'));
const support = join(work, 'support');
mkdirSync(join(support, 'Downloads'), { recursive: true });
mkdirSync(join(work, 'vaultwarden'));
const serverLog = join(out, 'vaultwarden.log');
const vault = spawn(vaultwarden, [], {
  env: {
    PATH: process.env.PATH, DATA_FOLDER: join(work, 'vaultwarden'), ROCKET_ADDRESS: '127.0.0.1', ROCKET_PORT: String(port), DOMAIN: server,
    ROCKET_TLS: `{certs=${JSON.stringify(certificate)},key=${JSON.stringify(join(dirname(certificate), 'key.pem'))}}`, SIGNUPS_ALLOWED: 'true', WEB_VAULT_ENABLED: 'false', DISABLE_ICON_DOWNLOAD: 'true', LOG_LEVEL: 'warn',
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
const logChunks = [];
vault.stdout.on('data', (chunk) => logChunks.push(chunk));
vault.stderr.on('data', (chunk) => logChunks.push(chunk));

const appResources = join(root, '.derived.noindex/xcode/Build/Products/Debug/Lilo.app/Contents/Resources');
const prelude = join(appResources, 'ChromeAPIBackgroundPrelude.js');
const originalPrelude = join(work, 'prelude.js');
copyFileSync(prelude, originalPrelude);
// The bundle is signed: a resource changed in place breaks its seal, and the keychain then asks about the test host.
const resign = () => spawnSync('codesign', ['--force', '--sign', identity, '--preserve-metadata=identifier,entitlements,requirements,flags,runtime',
  join(root, '.derived.noindex/xcode/Build/Products/Debug/Lilo.app')], { stdio: 'inherit' }).status === 0;

let failed = false;
try {
  await waitForServer();
  const fixture = await createAccount();
  const fixturePath = join(out, 'fixture.json');
  writeFileSync(fixturePath, `${JSON.stringify(fixture, null, 2)}\n`);
  failed = !runPhase('testBitwardenSignsInFillsAndOffersToSave', fixturePath);
  if (!failed) {
    // What a Lilo update does to the prelude: new code the worker must run once relaunched.
    const mark = randomUUID();
    writeFileSync(prelude, `${readFileSync(originalPrelude, 'utf8')}\nconsole.error('lilo-e2e-prelude', ${JSON.stringify(mark)});\n`);
    writeFileSync(fixturePath, `${JSON.stringify({ ...fixture, preludeMark: mark }, null, 2)}\n`);
    failed = !resign() || !runPhase('testBitwardenRunsTheNewPreludeAfterARelaunch', fixturePath);
  }
} catch (error) {
  console.error(error);
  failed = true;
} finally {
  copyFileSync(originalPrelude, prelude);
  resign();
  vault.kill();
  writeFileSync(serverLog, Buffer.concat(logChunks));
  rmSync(work, { recursive: true, force: true });
}
console.log(failed ? `ext-e2e-passwords failed: logs and results in ${out}` : 'ext-e2e-passwords passed');
process.exit(failed ? 1 : 0);

function runPhase(test, fixturePath) {
  const result = spawnSync('xcodebuild', ['test-without-building', ...xcodebuild, `-only-testing:LiloTests/PasswordManagerE2ETests/${test}`,
    '-resultBundlePath', join(out, `${test}.xcresult`)], {
    cwd: root,
    // LILO_KEEP_TEST_STORES: the WebKit stores the first process leaves are what the second one relaunches on.
    env: { ...process.env, TEST_RUNNER_LILO_E2E_FIXTURE: fixturePath, TEST_RUNNER_LILO_APP_SUPPORT_DIR: support, TEST_RUNNER_LILO_KEEP_TEST_STORES: '1' },
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
  });
  writeFileSync(join(out, `${test}.log`), `${result.stdout}${result.stderr}`);
  const failures = `${result.stdout}`.split('\n').filter((line) => /error: -\[|: error: /.test(line));
  console.log(`${test}: ${result.status === 0 ? 'passed' : `failed (xcodebuild ${result.status})`}`);
  for (const line of failures) console.log(`  ${line.trim()}`);
  return result.status === 0;
}

async function waitForServer() {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (vault.exitCode !== null) throw new Error(`Vaultwarden exited (${vault.exitCode}): ${Buffer.concat(logChunks)}`);
    try {
      if ((await fetch(`${server}/alive`)).ok) return;
    } catch { /* not listening yet */ }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('Vaultwarden did not start in 10 s');
}

// Bitwarden's client-side keys (its "Bitwarden security whitepaper"): the server only ever sees what they encrypt.
async function createAccount() {
  const email = `e2e-${randomBytes(4).toString('hex')}@example.com`;
  const password = randomBytes(18).toString('base64url');
  const iterations = 600000;
  const masterKey = pbkdf2Sync(password, email, iterations, 32, 'sha256');
  const masterPasswordHash = pbkdf2Sync(masterKey, password, 1, 32, 'sha256').toString('base64');
  // HKDF-Expand of the master key, one block each.
  const expand = (info) => createHmac('sha256', masterKey).update(Buffer.concat([Buffer.from(info), Buffer.from([1])])).digest();
  const encrypt = (data, key) => {
    const iv = randomBytes(16);
    const cipher = createCipheriv('aes-256-cbc', key.subarray(0, 32), iv);
    const body = Buffer.concat([cipher.update(data), cipher.final()]);
    const mac = createHmac('sha256', key.subarray(32, 64)).update(Buffer.concat([iv, body])).digest();
    return `2.${iv.toString('base64')}|${body.toString('base64')}|${mac.toString('base64')}`;
  };
  const userKey = randomBytes(64);
  const { publicKey, privateKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048, publicKeyEncoding: { type: 'spki', format: 'der' }, privateKeyEncoding: { type: 'pkcs8', format: 'der' },
  });
  const post = async (path, body, headers = {}) => {
    const json = typeof body !== 'string';
    const response = await fetch(`${server}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': json ? 'application/json' : 'application/x-www-form-urlencoded', Accept: 'application/json', ...headers },
      body: json ? JSON.stringify(body) : body,
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${path}: ${response.status} ${text}`);
    return text ? JSON.parse(text) : null;
  };
  const emailVerificationToken = await post('/identity/accounts/register/send-verification-email', { email, name: 'E2E' });
  await post('/identity/accounts/register/finish', {
    email, emailVerificationToken, masterPasswordHash, masterPasswordHint: null, kdf: 0, kdfIterations: iterations,
    userSymmetricKey: encrypt(userKey, Buffer.concat([expand('enc'), expand('mac')])),
    userAsymmetricKeys: { publicKey: publicKey.toString('base64'), encryptedPrivateKey: encrypt(privateKey, userKey) },
  });
  const { access_token: token } = await post('/identity/connect/token', new URLSearchParams({
    grant_type: 'password', username: email, password: masterPasswordHash, scope: 'api offline_access', client_id: 'web',
    deviceType: '10', deviceIdentifier: randomUUID(), deviceName: 'e2e',
  }).toString());
  const item = { name: 'Example login', username: 'alice@example.com', password: randomBytes(12).toString('base64url') };
  const text = (value) => encrypt(Buffer.from(value), userKey);
  const userId = JSON.parse(Buffer.from(token.split('.')[1], 'base64url')).sub;
  await post('/api/ciphers', {
    encryptedFor: userId, type: 1, name: text(item.name), notes: null, favorite: false, reprompt: 0, folderId: null, organizationId: null,
    // Bitwarden matches a login by base domain, so the test's login page matches it on any port.
    login: { username: text(item.username), password: text(item.password), uris: [{ uri: text('http://127.0.0.1/'), match: null }] },
  }, { Authorization: `Bearer ${token}` });
  return { server, email, password, item };
}
