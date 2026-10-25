// Usage: node scripts/top-manifests.mjs (rebuilds LiloTests/Extensions/top-manifests.json for TopManifestTests).
// Keeps each top extension's manifest and the default locale's messages it names, nothing else of the package.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { root } from './chrome-for-testing.mjs';

const list = JSON.parse(readFileSync(join(root, 'LiloTests/Extensions/top-extensions.json'), 'utf8'));
const out = join(root, 'LiloTests/Extensions/top-manifests.json');
const top = [...list.extensions, ...list.extra ?? []];
const prodVersion = readFileSync(join(root, 'Lilo/Engine/ChromeMasquerade.swift'), 'utf8').match(/Chrome\/([\d.]+)/)[1];
const dir = mkdtempSync(join(tmpdir(), 'top-manifests-'));

// One file of the package's zip, after the CRX3 header; unzip exits 1 on warnings it recovers from.
function unzipFile(zip, path) {
  const { status, stdout } = spawnSync('unzip', ['-p', '-C', zip, path], { maxBuffer: 64 << 20 });
  return status <= 1 && stdout.length ? stdout.toString('utf8').replace(/^﻿/, '') : null;
}

// A manifest or messages file Chrome reads but strict JSON does not (comments, trailing commas) is kept as written.
const parsed = (text) => {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
};

async function manifestOf(id) {
  const url = `https://clients2.google.com/service/update2/crx?response=redirect&os=mac&arch=arm64&prod=chromecrx&prodchannel=stable&prodversion=${prodVersion}&acceptformat=crx3&x=id%3D${id}%26installsource%3Dondemand%26uc`;
  const response = await fetch(url, { signal: AbortSignal.timeout(5 * 60_000) });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const crx = Buffer.from(await response.arrayBuffer());
  if (crx.toString('latin1', 0, 4) !== 'Cr24') throw new Error('not a CRX package');
  const zip = join(dir, `${id}.zip`);
  writeFileSync(zip, crx.subarray(12 + crx.readUInt32LE(8)));
  try {
    const manifest = unzipFile(zip, 'manifest.json');
    if (!manifest) throw new Error('no manifest.json');
    const entry = { manifest: parsed(manifest) };
    const locale = manifest.match(/"default_locale"\s*:\s*"([^"]+)"/)?.[1];
    const names = new Set([...manifest.matchAll(/__MSG_(\w+?)__/g)].map(([, name]) => name.toLowerCase()));
    const messages = locale && names.size ? unzipFile(zip, `_locales/${locale}/messages.json`) : null;
    const all = messages && parsed(messages);
    if (all) entry.messages = typeof all === 'string' ? all : Object.fromEntries(Object.entries(all).filter(([key]) => names.has(key.toLowerCase())));
    return entry;
  } finally {
    rmSync(zip, { force: true });
  }
}

const manifests = {};
const queue = [...top];
let failed = 0;
await Promise.all(Array.from({ length: 12 }, async () => {
  for (let entry = queue.shift(); entry; entry = queue.shift()) {
    try {
      manifests[entry.id] = await manifestOf(entry.id);
    } catch (error) {
      failed++;
      console.error(`${entry.id} ${entry.name}: ${error.message}`);
    }
  }
}));
rmSync(dir, { recursive: true, force: true });
const sorted = Object.fromEntries(top.map(({ id }) => id).filter((id) => manifests[id]).map((id) => [id, manifests[id]]));
writeFileSync(out, `${JSON.stringify({ measured: list.measured, extensions: sorted })}\n`);
console.log(`${Object.keys(sorted).length} manifests into ${out}, ${failed} failed`);
