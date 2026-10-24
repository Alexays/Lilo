// Chrome for Testing for the scripts that record Chrome's reference behavior: a branded Chrome no
// longer loads unpacked extensions from the command line.
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, mkdirSync, renameSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export const root = join(import.meta.dirname, '..');

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function fetchOK(url, timeoutMs) {
  const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response;
}

// The current stable build from Google's catalog, downloaded into .derived.noindex/ once; ditto keeps the
// app's framework symlinks intact. It unpacks beside the version folder, so a cut download never passes for one.
export async function stableChromeForTesting() {
  const platform = process.arch === 'arm64' ? 'mac-arm64' : 'mac-x64';
  const catalog = await (await fetchOK('https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json', 30_000)).json();
  const { version, downloads } = catalog.channels.Stable;
  const dir = join(root, '.derived.noindex/chrome-for-testing', version);
  const binary = join(dir, `chrome-${platform}`, 'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
  if (existsSync(binary)) return binary;
  const { url } = downloads.chrome.find((d) => d.platform === platform);
  const partial = `${dir}.partial`;
  rmSync(partial, { recursive: true, force: true });
  mkdirSync(partial, { recursive: true });
  const zip = join(partial, 'chrome.zip');
  writeFileSync(zip, Buffer.from(await (await fetchOK(url, 10 * 60_000)).arrayBuffer()));
  execFileSync('ditto', ['-x', '-k', zip, partial]);
  rmSync(zip);
  rmSync(dir, { recursive: true, force: true });
  renameSync(partial, dir);
  return binary;
}

// A headless Chrome in a fresh profile with only `extension` loaded, driven over CDP on a pipe, so
// Chrome quits with this process however it ends. Messages without an id (events) go to `onEvent`.
export async function launchChrome(binary, extension) {
  const profile = mkdtempSync(join(tmpdir(), 'chrome-for-testing-'));
  // An extension may download a file on install: it lands in the throwaway profile, never the user's Downloads.
  mkdirSync(join(profile, 'Default'), { recursive: true });
  writeFileSync(join(profile, 'Default', 'Preferences'), JSON.stringify({
    download: { default_directory: join(profile, 'Downloads'), prompt_for_download: false },
  }));
  const chrome = spawn(binary, [
    '--headless=new', `--user-data-dir=${profile}`, '--remote-debugging-pipe', '--no-first-run',
    '--no-default-browser-check', `--load-extension=${extension}`, `--disable-extensions-except=${extension}`,
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
  const [, , , input, output] = chrome.stdio;
  const browser = {
    onEvent: null,
    async close() {
      if (chrome.exitCode === null && chrome.signalCode === null) {
        chrome.kill();
        await once(chrome, 'exit');
      }
      rmSync(profile, { recursive: true, force: true, maxRetries: 5 });
    },
  };
  let nextId = 1;
  const pending = new Map();
  // Chrome ends each message with a NUL.
  let buffered = '';
  output.setEncoding('utf8');
  output.on('data', (chunk) => {
    const messages = (buffered + chunk).split('\0');
    buffered = messages.pop();
    for (const message of messages) {
      const data = JSON.parse(message);
      const call = pending.get(data.id);
      if (!call) {
        if (data.method) browser.onEvent?.(data);
        continue;
      }
      pending.delete(data.id);
      if (data.error) call.reject(new Error(data.error.message));
      else call.resolve(data.result);
    }
  });
  chrome.on('exit', () => {
    for (const call of pending.values()) call.reject(new Error('Chrome exited'));
    pending.clear();
  });
  browser.send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    input.write(JSON.stringify({ id, method, params, sessionId }) + '\0');
  });
  try {
    await browser.send('Browser.getVersion');
    await browser.send('Browser.setDownloadBehavior', { behavior: 'allowAndName', downloadPath: join(profile, 'Downloads') });
  } catch (error) {
    await browser.close();
    throw error;
  }
  return browser;
}
