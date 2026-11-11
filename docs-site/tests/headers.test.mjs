// Runs on the build `make docs-test` makes first.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
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

test("pages hold no script the CSP cannot hash, and only the inline scripts it was checked with", () => {
  const html = readdirSync(dist, { recursive: true }).filter((entry) => entry.endsWith(".html"));
  for (const entry of html) {
    const page = readFileSync(join(dist, entry), "utf-8").replace(/<script\b[^>]*>[\s\S]*?<\/script>/gu, (script) => script.slice(0, script.indexOf(">") + 1));
    for (const [tag] of page.matchAll(/<[a-zA-Z][^>]*>/gu)) {
      const attributes = tag.replace(/"[^"]*"|'[^']*'/gu, '""');
      assert.doesNotMatch(attributes, /\son[a-z]+\s*=/iu, `${entry}: event handler attribute in ${tag.slice(0, 80)}`);
      assert.doesNotMatch(tag, /\s(?:href|src|action|formaction)\s*=\s*["']?\s*javascript:/iu, `${entry}: javascript: URL in ${tag.slice(0, 80)}`);
      const src = tag.match(/^<script\b[^>]*\ssrc="([^"]*)"/u)?.[1];
      if (src !== undefined) assert.match(src, /^\/(?!\/)/u, `${entry}: script from another origin: ${src}`);
    }
  }
  const hashes = scriptSrc.match(/'sha256-/gu)?.length;
  // A Blume upgrade that adds or changes an inline script lands here: before raising the number, read
  // the new script in dist/ and check it runs nothing a page or URL can inject into.
  assert.equal(hashes, 6, `the CSP now hashes ${hashes} inline scripts, not 6: read the new ones in dist/ before updating this number`);
});

test("no later _headers rule detaches or replaces the CSP", () => {
  const later = headers.slice(headers.indexOf("\n\n"));
  assert.doesNotMatch(later, /^\s*!\s*Content-Security-Policy/imu);
  // Cloudflare joins a header set by several rules, so a later CSP adds a policy; only Blume's SVG sandbox may.
  for (const [, value] of later.matchAll(/^\s*Content-Security-Policy:\s*(.*)$/gimu)) assert.equal(value, "sandbox");
});

test("only Cloudflare's files are deployed", () => {
  assert.ok(!existsSync(join(dist, "vercel.json")), "dist/vercel.json would be served as a page");
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
