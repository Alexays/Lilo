// Usage: node scripts/record-chrome-contracts.mjs [Chrome for Testing binary] (writes chrome-contracts.json).
// Without a binary, it downloads the current stable Chrome for Testing into .derived.noindex/.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { launchChrome, root, sleep, stableChromeForTesting } from './chrome-for-testing.mjs';

const chromeBinary = process.argv[2] ?? await stableChromeForTesting();
if (!existsSync(chromeBinary)) {
  console.error(`no Chrome for Testing at ${chromeBinary}`);
  process.exit(2);
}
// The pages the messaging and content-script cases open, as ChromeContractTests serves them.
const server = createServer((request, response) => response.end('<!doctype html><title>page</title><p>page</p>'));
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const site = `http://127.0.0.1:${server.address().port}`;
const browser = await launchChrome(chromeBinary, join(root, 'test-extensions/extension-contracts'));
const { send } = browser;

try {
  // The probe's worker carries its extension id.
  let extensionId;
  for (let i = 0; i < 100 && !extensionId; i++) {
    const { targetInfos } = await send('Target.getTargets');
    // Chrome's own component extensions have targets too: the probe is the one running worker.js.
    extensionId = targetInfos.map((t) => t.url.match(/^chrome-extension:\/\/([a-p]{32})\/worker\.js$/)?.[1]).find(Boolean);
    if (!extensionId) await sleep(100);
  }
  // A page in a new tab, once `ready` evaluates to true in it: it has no execution context until it starts loading.
  const open = async (url, ready) => {
    const { targetId } = await send('Target.createTarget', { url });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    for (let i = 0; i < 100; i++) {
      const loaded = await send('Runtime.evaluate', { expression: ready, returnByValue: true }, sessionId)
        .then(({ result }) => result.value === true, () => false);
      if (loaded) break;
      await sleep(100);
    }
    return sessionId;
  };
  const run = async (expression, sessionId) => {
    const { result, exceptionDetails } = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
    return result.value;
  };
  const contract = await open(`chrome-extension://${extensionId}/contract.html?site=${encodeURIComponent(site)}`, "typeof window.runContracts === 'function'");
  const results = await run('window.runContracts()', contract);
  const contentScript = await run('window.contentSurfaces()', contract);
  // What the page's own scripts see, as ChromeContractTests reads it.
  const page = await open(`${site}/page`, "document.readyState === 'complete'");
  contentScript.page = await run(`${readFileSync(join(root, 'test-extensions/extension-contracts/surface.js'), 'utf8')}\nworldSurface()`, page);
  const { product } = await send('Browser.getVersion');
  const out = join(root, 'LiloTests/Extensions/chrome-contracts.json');
  writeFileSync(out, `${JSON.stringify({ chrome: product, results, contentScript }, null, 1)}\n`);
  console.log(`${Object.keys(results).length} cases recorded from ${product} into ${out}`);
} finally {
  await browser.close();
  server.close();
}
