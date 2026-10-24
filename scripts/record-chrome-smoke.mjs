// Usage: node scripts/record-chrome-smoke.mjs [id,id,...] (Chrome's reference for RealExtensionSmokeTests).
// Errors depend on timing, so re-recording an extension version in the same Chrome adds to its recorded errors.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { launchChrome, root, sleep, stableChromeForTesting } from './chrome-for-testing.mjs';

const listPath = join(root, 'LiloTests/Extensions/top-extensions.json');
const out = join(root, 'LiloTests/Extensions/chrome-smoke.json');
const list = JSON.parse(readFileSync(listPath, 'utf8'));
const top = [...list.extensions, ...list.extra ?? []];
const only = process.argv[2] ? new Set(process.argv[2].split(',')) : null;
const binary = await stableChromeForTesting();
const chromeVersion = execFileSync(binary, ['--version'], { encoding: 'utf8' }).match(/[\d.]+/)[0];
const previous = existsSync(out) ? JSON.parse(readFileSync(out, 'utf8')) : { extensions: {} };
const recorded = previous.extensions;

// As long as RealExtensionSmokeTests waits for a worker and for a popup's text, plus a margin after.
const workerTimeout = 10_000;
const popupTimeout = 40_000;
const minimumCapture = 20_000;
const tailCapture = 5_000;

const varint = (buffer, offset) => {
  let value = 0;
  for (let scale = 1; ; scale *= 128) {
    const byte = buffer[offset++];
    value += (byte & 0x7f) * scale;
    if (byte < 0x80) return [value, offset];
  }
};

// The length-delimited fields of a protobuf message, as [field number, bytes].
function* protobufFields(buffer) {
  for (let offset = 0; offset < buffer.length;) {
    const [tag, start] = varint(buffer, offset);
    if (tag % 8 === 0) {
      offset = varint(buffer, start)[1];
    } else if (tag % 8 === 2) {
      const [length, data] = varint(buffer, start);
      yield [Math.floor(tag / 8), buffer.subarray(data, data + length)];
      offset = data + length;
    } else {
      throw new Error(`unexpected protobuf wire type ${tag % 8}`);
    }
  }
}

const extensionIdOf = (key) => createHash('sha256').update(key).digest('hex').slice(0, 32)
  .replace(/./g, (digit) => 'abcdefghijklmnop'[parseInt(digit, 16)]);

// Unpacks a store CRX3 into `dir`, keyed with the store's public key so Chrome runs it under its
// store id, as Lilo does.
function unpackCRX(crx, id, dir) {
  if (crx.toString('latin1', 0, 4) !== 'Cr24' || crx.readUInt32LE(4) !== 3) throw new Error('not a CRX3 package');
  const headerEnd = 12 + crx.readUInt32LE(8);
  let key;
  // CrxFileHeader fields 2 and 3 are AsymmetricKeyProofs, whose field 1 is a public key.
  for (const [field, proof] of protobufFields(crx.subarray(12, headerEnd))) {
    if (field !== 2 && field !== 3) continue;
    for (const [proofField, bytes] of protobufFields(proof)) {
      if (proofField === 1 && extensionIdOf(bytes) === id) key = bytes;
    }
  }
  if (!key) throw new Error('no public key for the extension id in the CRX header');
  const zip = join(dir, 'package.zip');
  writeFileSync(zip, crx.subarray(headerEnd));
  const extension = join(dir, id);
  // unzip exits 1 on warnings it recovers from.
  const { status } = spawnSync('unzip', ['-q', '-o', zip, '-d', extension], { stdio: 'ignore' });
  if (status > 1) throw new Error(`unzip failed with status ${status}`);
  // Some packages carry read-only modes, which would block the key below and the cleanup.
  execFileSync('chmod', ['-R', 'u+w', extension]);
  const manifestPath = join(extension, 'manifest.json');
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8').replace(/^﻿/, ''));
  manifest.key = key.toString('base64');
  writeFileSync(manifestPath, JSON.stringify(manifest));
  return { extension, manifest };
}

async function capture(browser, id, manifest) {
  const { send } = browser;
  const origin = `chrome-extension://${id}/`;
  const targetURLs = new Map();
  const sessionTargets = new Map();
  const errors = new Set();
  // The first line only: what follows is a stack, which differs between engines.
  const report = (message) => errors.add(String(message).split('\n')[0].slice(0, 500));
  // Errors count from the extension's own pages and workers, and from its content scripts, which WebKit
  // reports as the extension's: those run in a world of the extension's origin. The web pages' own do not.
  const contentWorlds = new Set();
  let workerSession;
  browser.onEvent = ({ method, params, sessionId }) => {
    if (method === 'Target.attachedToTarget') {
      sessionTargets.set(params.sessionId, params.targetInfo.targetId);
      targetURLs.set(params.targetInfo.targetId, params.targetInfo.url);
      if (params.targetInfo.type === 'service_worker' && params.targetInfo.url.startsWith(origin)) workerSession = params.sessionId;
      for (const command of ['Runtime.enable', 'Log.enable', 'Runtime.runIfWaitingForDebugger']) {
        send(command, {}, params.sessionId).catch(() => {});
      }
    } else if (method === 'Target.targetInfoChanged') {
      targetURLs.set(params.targetInfo.targetId, params.targetInfo.url);
    } else if (method === 'Runtime.executionContextCreated') {
      if (`${params.context.origin}/` === origin) contentWorlds.add(`${sessionId} ${params.context.id}`);
    } else if (
      targetURLs.get(sessionTargets.get(sessionId))?.startsWith(origin)
      || contentWorlds.has(`${sessionId} ${params.executionContextId ?? params.exceptionDetails?.executionContextId}`)
    ) {
      if (method === 'Runtime.exceptionThrown') {
        const { exception, text } = params.exceptionDetails;
        report(exception?.description ?? exception?.value ?? text);
      } else if (method === 'Runtime.consoleAPICalled' && (params.type === 'error' || params.type === 'assert')) {
        report(params.args.map((arg) => String(arg.value ?? arg.description ?? arg.unserializableValue ?? '').split('\n')[0]).join(' '));
      } else if (method === 'Log.entryAdded' && params.entry.level === 'error') {
        report(params.entry.text);
      }
    }
  };
  const start = Date.now();
  await send('Target.setDiscoverTargets', { discover: true });
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });

  if (manifest.background?.service_worker) {
    for (let waited = 0; waited < workerTimeout; waited += 100) {
      // As RealExtensionSmokeTests waits for the worker to connect: once the worker has its bindings, its top-level code
      // runs in the same task, before the evaluation answers. An evaluation answers earlier, before the bindings.
      const started = workerSession && await send('Runtime.evaluate', { expression: "typeof chrome === 'object'", returnByValue: true }, workerSession)
        .then(({ result }) => result.value === true, () => false);
      if (started) break;
      await sleep(100);
    }
  }
  let popupText;
  const popup = manifest.action?.default_popup;
  if (popup) {
    // Resolved as Lilo resolves it: a query or fragment stays one.
    const { targetId } = await send('Target.createTarget', { url: new URL(popup, origin).href });
    const deadline = Date.now() + popupTimeout;
    let text = '';
    while (!text && Date.now() < deadline) {
      await sleep(250);
      const session = [...sessionTargets].find(([, target]) => target === targetId)?.[0];
      if (!session) continue;
      // As RealExtensionSmokeTests reads it: a form control and no text is no blank popup.
      const expression = "document.body?.innerText || (document.body?.querySelector('input, button, select, textarea') ? '[form control]' : '')";
      text = await send('Runtime.evaluate', { expression, returnByValue: true }, session)
        .then(({ result }) => result.value ?? '', () => '');
    }
    popupText = text.length > 0;
  }
  await sleep(Math.max(tailCapture, minimumCapture - (Date.now() - start)));
  return { popupText, errors: [...errors] };
}

async function record({ name, id }) {
  const dir = mkdtempSync(join(tmpdir(), 'chrome-smoke-'));
  try {
    const url = `https://clients2.google.com/service/update2/crx?response=redirect&prodversion=${chromeVersion}&acceptformat=crx3&x=id%3D${id}%26uc`;
    const response = await fetch(url);
    if (!response.ok) throw new Error(`download: HTTP ${response.status}`);
    const { extension, manifest } = unpackCRX(Buffer.from(await response.arrayBuffer()), id, dir);
    const browser = await launchChrome(binary, extension);
    try {
      return { name, version: manifest.version, ...await capture(browser, id, manifest) };
    } finally {
      await browser.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true, maxRetries: 5 });
  }
}

const queue = top.filter(({ id }) => !only || only.has(id));
let failed = 0;
// A few Chromes at a time, each in its own profile.
await Promise.all(Array.from({ length: 4 }, async () => {
  for (let entry = queue.shift(); entry; entry = queue.shift()) {
    try {
      const { version, popupText, errors, ...rest } = await record(entry);
      const before = recorded[entry.id];
      if (previous.chrome === chromeVersion && before?.version === version) errors.unshift(...before.errors.filter((e) => !errors.includes(e)));
      recorded[entry.id] = { ...rest, version, popupText, errors };
      console.log(`${entry.id} ${entry.name} ${version}: popup ${popupText ?? 'none'}, ${errors.length} errors`);
    } catch (error) {
      failed++;
      console.error(`${entry.id} ${entry.name}: not recorded: ${error.message}`);
    }
  }
}));
const extensions = Object.fromEntries(top.filter(({ id }) => recorded[id]).map(({ id }) => [id, recorded[id]]));
writeFileSync(out, `${JSON.stringify({ chrome: chromeVersion, extensions }, null, 1)}\n`);
console.log(`${Object.keys(extensions).length} extensions recorded from Chrome ${chromeVersion} into ${out}`);
process.exit(failed ? 1 : 0);
