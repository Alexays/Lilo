import { readFile } from 'node:fs/promises';
import ts from 'typescript';

// A service worker has none of these: the prelude and the gap module chunks it may carry must never name them.
// Only identifiers count, so Chrome's error messages may still say "window" or "document".
const forbidden = new Set(['window', 'document', 'webkit', 'messageHandlers']);

const extensions = new URL('../../', import.meta.url);
const chunks = JSON.parse(await readFile(new URL('ChromeAPIGapModules.json', extensions), 'utf8'));
const sources = [await readFile(new URL('ChromeAPIBackgroundPrelude.js', extensions), 'utf8'), ...chunks.map((chunk) => chunk.source)];

const matches = new Set();
for (const text of sources) {
  (function visit(node) {
    if (ts.isIdentifier(node) && forbidden.has(node.text)) matches.add(node.text);
    ts.forEachChild(node, visit);
  })(ts.createSourceFile('prelude.js', text, ts.ScriptTarget.Latest, true));
}

if (matches.size > 0) {
  throw new Error(`ChromeAPIBackgroundPrelude.js or ChromeAPIGapModules.json is not service-worker-safe; found: ${[...matches].join(', ')}`);
}
