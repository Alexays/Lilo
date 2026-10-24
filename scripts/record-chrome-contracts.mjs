// Usage: node scripts/record-chrome-contracts.mjs [Chrome for Testing binary] (writes chrome-contracts.json).
// Without a binary, it downloads the current stable Chrome for Testing into .derived.noindex/.
import { existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { launchChrome, root, sleep, stableChromeForTesting } from './chrome-for-testing.mjs';

const chromeBinary = process.argv[2] ?? await stableChromeForTesting();
if (!existsSync(chromeBinary)) {
  console.error(`no Chrome for Testing at ${chromeBinary}`);
  process.exit(2);
}
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
  const { targetId } = await send('Target.createTarget', { url: `chrome-extension://${extensionId}/contract.html` });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  // The page has no execution context until it starts loading.
  for (let i = 0; i < 100; i++) {
    const ready = await send('Runtime.evaluate', { expression: 'typeof window.runContracts', returnByValue: true }, sessionId)
      .then(({ result }) => result.value === 'function', () => false);
    if (ready) break;
    await sleep(100);
  }
  const { result, exceptionDetails } = await send('Runtime.evaluate', {
    expression: 'window.runContracts()', awaitPromise: true, returnByValue: true,
  }, sessionId);
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
  const { product } = await send('Browser.getVersion');
  const out = join(root, 'LiloTests/Extensions/chrome-contracts.json');
  writeFileSync(out, `${JSON.stringify({ chrome: product, results: result.value }, null, 1)}\n`);
  console.log(`${Object.keys(result.value).length} cases recorded from ${product} into ${out}`);
} finally {
  await browser.close();
}
