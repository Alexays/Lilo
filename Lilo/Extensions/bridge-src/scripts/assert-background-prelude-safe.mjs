import { readFile } from 'node:fs/promises';
import ts from 'typescript';

// A service worker has none of these: the prelude must never name them. Only identifiers count, so
// Chrome's error messages may still say "window" or "document".
const forbidden = new Set(['window', 'document', 'webkit', 'messageHandlers']);

const preludeURL = new URL('../../ChromeAPIBackgroundPrelude.js', import.meta.url);
const source = ts.createSourceFile('prelude.js', await readFile(preludeURL, 'utf8'), ts.ScriptTarget.Latest, true);

const matches = new Set();
(function visit(node) {
  if (ts.isIdentifier(node) && forbidden.has(node.text)) matches.add(node.text);
  ts.forEachChild(node, visit);
})(source);

if (matches.size > 0) {
  throw new Error(`ChromeAPIBackgroundPrelude.js is not service-worker-safe; found: ${[...matches].join(', ')}`);
}
