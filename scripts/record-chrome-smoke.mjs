// Usage: node scripts/record-chrome-smoke.mjs [id,id,...] (Chrome's reference for RealExtensionSmokeTests).
// Errors and renders depend on timing, so re-recording an extension version in the same Chrome adds to its recorded
// errors, page changes and context menu items, and keeps the fuller fingerprint of each page: a loaded machine can
// leave a page on its loading screen.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
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
const optionsTimeout = 20_000;
const minimumCapture = 20_000;
const tailCapture = 5_000;
// A page counts as rendered once its fingerprint has held still that long, and no earlier than `settleMinimum`
// after it opened: a loading screen that gives way to the UI must not pass for the UI.
const settleMinimum = 5_000;
const settleQuiet = 2_000;
// How long content scripts get on the test page before its changes are read.
const pageSettle = 4_000;

const extensionsDir = join(root, 'LiloTests/Extensions');
const probes = readFileSync(join(extensionsDir, 'smoke-probes.js'), 'utf8');
const smokePage = readFileSync(join(extensionsDir, 'smoke-page.html'), 'utf8');
// Its images and frames answer an image, as RealExtensionSmokeTests' server does.
const gif = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');
const server = createServer((request, response) => {
  if (request.url === '/') response.writeHead(200, { 'Content-Type': 'text/html' }).end(smokePage);
  else response.writeHead(200, { 'Content-Type': 'image/gif' }).end(gif);
}).listen(0, '127.0.0.1');
await new Promise((resolve) => server.once('listening', resolve));
const pageURL = `http://127.0.0.1:${server.address().port}/`;

// As RealExtensionSmokeTests compares fingerprints: `tokens` shows most of `expected`.
const covers = (tokens, expected) => {
  const shown = new Set(tokens.split(' '));
  return expected.size > 0 && [...expected].filter((token) => shown.has(token)).length * 2 >= expected.size;
};

// Runs before the worker's own code, beside it so its relative imports resolve as before: it notes the context
// menu items the worker creates, and `__liloSmokeMenus(url)` lists the contexts of each leaf item that still exists
// and applies on `url` (Chrome has no call listing them). It passes the worker's own callbacks through untouched,
// so an unchecked lastError reports as it would.
const menusHook = `(() => {
  const api = globalThis.chrome?.contextMenus;
  if (!api) return;
  const created = new Map();
  const { create, update } = api;
  api.create = function (properties, ...rest) {
    const id = create.call(this, properties, ...rest);
    created.set(id, { ...properties });
    return id;
  };
  api.update = function (id, properties, ...rest) {
    if (created.has(id)) Object.assign(created.get(id), properties);
    return update.call(this, id, properties, ...rest);
  };
  const matches = (pattern, url) => pattern === '<all_urls>'
    || new RegExp('^' + pattern.split('*').map((part) => part.replace(/\\W/g, '\\\\$&')).join('.*') + '$').test(url);
  globalThis.__liloSmokeMenus = async (url) => {
    const exists = await Promise.all([...created.keys()].map((id) => new Promise((resolve) => {
      update.call(api, id, {}, () => resolve(!chrome.runtime.lastError));
    })));
    const items = [...created].filter((_, index) => exists[index]);
    const parents = new Set(items.map(([, item]) => item.parentId));
    return items
      .filter(([id, item]) => !parents.has(id) && item.type !== 'separator' && item.visible !== false
        && (!item.documentUrlPatterns || item.documentUrlPatterns.some((pattern) => matches(pattern, url))))
      .map(([, item]) => [item.contexts ?? 'page'].flat().sort().join(','));
  };
})();
`;

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
  // Some packages carry read-only files or untraversable folders, which would block the key below and the cleanup.
  execFileSync('chmod', ['-R', 'u+rwX', extension]);
  const manifestPath = join(extension, 'manifest.json');
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8').replace(/^﻿/, ''));
  manifest.key = key.toString('base64');
  const worker = manifest.background?.service_worker;
  if (worker) {
    const folder = dirname(join(extension, worker));
    const original = `./${encodeURI(worker.split('/').pop())}`;
    writeFileSync(join(folder, '__lilo_smoke_menus.js'), menusHook);
    writeFileSync(join(folder, '__lilo_smoke_worker.js'), manifest.background.type === 'module'
      ? `import './__lilo_smoke_menus.js';\nimport '${original}';\n`
      : `importScripts('__lilo_smoke_menus.js', '${original}');\n`);
    manifest.background.service_worker = join(dirname(worker), '__lilo_smoke_worker.js');
  }
  writeFileSync(manifestPath, JSON.stringify(manifest));
  return { extension, manifest: { ...manifest, background: manifest.background && { ...manifest.background, service_worker: worker } } };
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

  // A stopped worker's session never answers.
  const evaluate = (expression, session) => Promise.race([
    send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, session).then(({ result }) => result.value, () => undefined),
    sleep(3_000),
  ]);
  // The milliseconds the worker takes to run its top-level code, undefined when it does not within `workerTimeout`.
  const workerStarts = async (resume) => {
    for (const started = Date.now(); Date.now() - started < workerTimeout; await sleep(100)) {
      // A worker that starts again does in the same session, where it waits for the debugger each time.
      if (resume) send('Runtime.runIfWaitingForDebugger', {}, workerSession).catch(() => {});
      // As RealExtensionSmokeTests waits for the worker to connect: once the worker has its bindings, its top-level code
      // runs in the same task, before the evaluation answers. An evaluation answers earlier, before the bindings.
      if (workerSession && await evaluate("typeof chrome === 'object'", workerSession) === true) return Date.now() - started;
    }
    return undefined;
  };
  const sessionOf = async (targetId) => {
    for (const opened = Date.now(); Date.now() - opened < 5_000; await sleep(50)) {
      const session = [...sessionTargets].find(([, target]) => target === targetId)?.[0];
      if (session) return session;
    }
    return undefined;
  };
  // A tab's fingerprint (smoke-probes.js) once it settles, and the milliseconds until it first showed most of it,
  // as RealExtensionSmokeTests measures its own; undefined for a page that shows nothing within `timeout`.
  const render = async (url, timeout, background = false) => {
    const { targetId } = await send('Target.createTarget', { url, background });
    const opened = Date.now();
    const samples = [];
    for (let still = opened; Date.now() - opened < timeout;) {
      await sleep(250);
      const session = await sessionOf(targetId);
      // Chrome's own error page (a blocked page) is no reference for what the extension shows.
      const tokens = (session && await evaluate(`location.protocol === 'chrome-error:' ? '' : (${probes}).fingerprint().join(' ')`, session)) || '';
      if (tokens !== samples.at(-1)?.tokens) still = Date.now();
      samples.push({ at: Date.now() - opened, tokens });
      if (tokens && Date.now() - opened >= settleMinimum && Date.now() - still >= settleQuiet) break;
    }
    await send('Target.closeTarget', { targetId }).catch(() => {});
    const tokens = samples.findLast((sample) => sample.tokens)?.tokens;
    if (!tokens) return undefined;
    const settled = new Set(tokens.split(' '));
    return { tokens, ms: samples.find((sample) => covers(sample.tokens, settled)).at };
  };

  const recording = {};
  const worker = manifest.background?.service_worker;
  if (worker) await workerStarts();
  // Resolved as Lilo resolves it: a query or fragment stays one.
  const popup = manifest.action?.default_popup && new URL(manifest.action.default_popup, origin).href;
  if (popup) {
    recording.popup = await render(popup, popupTimeout);
    recording.popupText = recording.popup !== undefined;
  }
  const { targetId: page } = await send('Target.createTarget', { url: pageURL });
  await sleep(pageSettle);
  const pageSession = await sessionOf(page);
  // Chrome's own error page, as a blocked test page, is no reference for what the extension changes.
  const changes = pageSession && await evaluate(`location.protocol === 'chrome-error:' ? [] : (${probes}).pageChanges(${JSON.stringify(smokePage)})`, pageSession);
  if (changes?.length) recording.page = changes;
  await send('Target.closeTarget', { targetId: page }).catch(() => {});
  const menus = workerSession && await evaluate(`globalThis.__liloSmokeMenus?.(${JSON.stringify(pageURL.replace(/:\d+/, ''))})`, workerSession);
  if (menus?.length) recording.menus = menus.sort();
  const options = manifest.options_ui?.page ?? manifest.options_page;
  if (options) recording.options = await render(new URL(options, origin).href, optionsTimeout);
  if (worker && popup) {
    // As an idle worker stops: the popup then opens on a stopped worker, which its messages start again. It opens as
    // RealExtensionSmokeTests' idle check opens it, as a popup over a blank tab.
    await send('Target.closeTarget', { targetId: sessionTargets.get(workerSession) }).catch(() => {});
    for (const since = Date.now(); Date.now() - since < 3_000 && await evaluate('1', workerSession) === 1;) await sleep(50);
    const { targetId: blank } = await send('Target.createTarget', { url: 'about:blank' });
    const [again, restarted] = await Promise.all([render(popup, popupTimeout, true), workerStarts(true)]);
    await send('Target.closeTarget', { targetId: blank }).catch(() => {});
    recording.workerRestartMs = restarted;
    recording.restartPopup = again ?? { tokens: '' };
  }
  await sleep(Math.max(tailCapture, minimumCapture - (Date.now() - start)));
  return { ...recording, errors: [...errors] };
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
await Promise.all(Array.from({ length: 6 }, async () => {
  for (let entry = queue.shift(); entry; entry = queue.shift()) {
    try {
      const { name, version, errors, ...rest } = await record(entry);
      const before = recorded[entry.id];
      if (previous.chrome === chromeVersion && before?.version === version) {
        errors.unshift(...before.errors.filter((e) => !errors.includes(e)));
        const size = (render) => (render?.tokens ? render.tokens.split(' ').length : 0);
        for (const key of ['popup', 'options', 'restartPopup']) if (size(before[key]) > size(rest[key])) rest[key] = before[key];
        if (before.popupText) rest.popupText = true;
        if (before.page) rest.page = [...new Set([...rest.page ?? [], ...before.page])].sort();
        if (before.menus?.length > (rest.menus?.length ?? 0)) rest.menus = before.menus;
        rest.workerRestartMs = Math.min(rest.workerRestartMs ?? Infinity, before.workerRestartMs ?? Infinity);
        if (rest.workerRestartMs === Infinity) delete rest.workerRestartMs;
      }
      recorded[entry.id] = { name, version, ...rest, errors };
      const words = (render) => (render ? `${render.tokens.split(' ').length} tokens in ${render.ms} ms` : 'nothing');
      console.log(`${entry.id} ${entry.name} ${version}: popup ${rest.popup === undefined && !rest.popupText ? 'none' : words(rest.popup)}, `
        + `options ${rest.options === undefined ? 'none' : words(rest.options)}, page ${rest.page?.length ?? 0} changes, menus ${rest.menus?.length ?? 0}, `
        + `worker restart ${rest.workerRestartMs ?? 'none'} ms, ${errors.length} errors`);
    } catch (error) {
      failed++;
      console.error(`${entry.id} ${entry.name}: not recorded: ${error.message}`);
    }
  }
}));
const extensions = Object.fromEntries(top.filter(({ id }) => recorded[id]).map(({ id }) => [id, recorded[id]]));
writeFileSync(out, `${JSON.stringify({ chrome: chromeVersion, extensions }, null, 1)}\n`);
console.log(`${Object.keys(extensions).length} extensions recorded from Chrome ${chromeVersion} into ${out}`);
server.close();
process.exit(failed ? 1 : 0);
