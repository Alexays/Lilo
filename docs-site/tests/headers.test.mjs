// Runs on the build `make docs-test` makes first.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { inlineScripts, scriptHash } from "../scripts/headers.mjs";

const dist = fileURLToPath(new URL("../dist", import.meta.url));
const headers = readFileSync(join(dist, "_headers"), "utf-8");
const csp = headers.match(/^ {2}Content-Security-Policy: (.+)$/mu)?.[1] ?? "";
const scriptSrc = csp.split("; ").find((directive) => directive.startsWith("script-src ")) ?? "";

test("every inline script of every page is allowed by its hash", () => {
  const html = readdirSync(dist, { recursive: true }).filter((entry) => entry.endsWith(".html"));
  assert.ok(html.length > 50, `only ${html.length} pages built`);
  for (const entry of html) {
    for (const body of inlineScripts(readFileSync(join(dist, entry), "utf-8"))) {
      assert.ok(scriptSrc.includes(scriptHash(body)), `${entry}: inline script missing from the CSP: ${body.slice(0, 60)}`);
    }
  }
});

test("scripts never run inline without a hash", () => {
  assert.match(scriptSrc, /^script-src 'self' 'sha256-/u);
  assert.doesNotMatch(scriptSrc, /'unsafe-inline'|'unsafe-eval'/u);
  assert.match(csp, /default-src 'none'/u);
});

test("Blume's own header rules stay below ours", () => {
  assert.ok(headers.startsWith("/*\n  Content-Security-Policy: "));
  assert.match(headers, /^\/\*\.md\n {2}Content-Type: text\/markdown; charset=utf-8$/mu);
  assert.match(headers, /^\/\.well-known\/api-catalog$/mu);
});

test("the inline script reader skips external scripts and data blocks", () => {
  const html = `<script src="/a.js"></script><script type="application/ld+json">{}</script>
<script type="application/json">[]</script><script>run()</script><script type="module">go()</script>`;
  assert.deepEqual(inlineScripts(html), ["run()", "go()"]);
});
