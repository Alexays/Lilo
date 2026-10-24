// Usage: node scripts/top-extensions.mjs [count=500] (rebuilds LiloTests/Extensions/top-extensions.json).
// The store rounds user counts (to the million above one million), so ties are ordered by id.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const root = join(import.meta.dirname, '..');
const count = Number(process.argv[2] ?? 500);
const listPath = join(root, 'LiloTests/Extensions/top-extensions.json');

// The RPC behind the store's pages: CWFOxc lists the categories, zTyKYc a category's extensions.
async function rpc(id, request) {
  const response = await fetch(`https://chromewebstore.google.com/_/ChromeWebStoreConsumerFeUi/data/batchexecute?rpcids=${id}&hl=en&rt=c`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
    body: new URLSearchParams({ 'f.req': JSON.stringify([[[id, JSON.stringify(request), null, 'generic']]]) }),
  });
  if (!response.ok) throw new Error(`${id}: HTTP ${response.status}`);
  // Chunks of `length\njson`; the answer is the wrb.fr entry for the RPC.
  for (const line of (await response.text()).split('\n')) {
    if (!line.startsWith('[["wrb.fr"')) continue;
    const [[, rpcId, payload]] = JSON.parse(line);
    if (rpcId === id && payload) return JSON.parse(payload);
  }
  throw new Error(`${id}: no answer`);
}

// Store items are arrays starting with the extension id, its name at 2 and its user count at 14.
function* items(node) {
  if (!Array.isArray(node)) return;
  if (typeof node[0] === 'string' && /^[a-p]{32}$/.test(node[0]) && typeof node[2] === 'string' && typeof node[14] === 'number') {
    yield { name: node[2], id: node[0], users: node[14] };
    return;
  }
  for (const child of node) yield* items(child);
}

const categories = JSON.stringify(await rpc('CWFOxc', [1])).match(/"[a-z_]+\/[a-z_]+"/g).map((c) => JSON.parse(c));
const found = new Map();
for (const category of new Set(categories)) {
  const listed = [...items(await rpc('zTyKYc', [[null, [[3, category, null, null, 2, [1000]]]]]))];
  console.log(`${category}: ${listed.length}`);
  for (const item of listed) found.set(item.id, item);
}
// Category pages leave out some of the most used extensions (McAfee WebAdvisor, AdBlock, Xunlei): each
// store page (xY2Ddd) also lists related extensions, so the pages of the most used and of those listed
// before add theirs, until the most used have all been read.
const top = () => [...found.values()].sort((a, b) => b.users - a.users || (a.id < b.id ? -1 : 1)).slice(0, count);
const read = new Set();
let pending = JSON.parse(readFileSync(listPath, 'utf8')).extensions.map(({ id }) => id);
while (pending.length) {
  await Promise.all(Array.from({ length: 8 }, async () => {
    for (let id = pending.shift(); id; id = pending.shift()) {
      read.add(id);
      const [own, ...related] = [...items(await rpc('xY2Ddd', [id]))];
      if (own?.id !== id) { found.delete(id); continue; }
      found.set(id, own);
      for (const item of related) if (!found.has(item.id)) found.set(item.id, item);
    }
  }));
  pending = top().map(({ id }) => id).filter((id) => !read.has(id));
}
const extensions = top();
writeFileSync(listPath, `${JSON.stringify({
  measured: new Date().toISOString().slice(0, 10),
  source: `Chrome Web Store user counts: the ${count} most used of every store category's first 1000 extensions and of those their store pages relate (make top-extensions)`,
  extensions,
}, null, 1)}\n`);
console.log(`${extensions.length} of ${found.size} extensions, down to ${extensions.at(-1)?.users} users`);
