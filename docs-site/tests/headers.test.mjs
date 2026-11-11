// Runs on the build `make docs-test` makes first.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { createHash } from "node:crypto";

import { inlineScripts, scriptHash, START_TAG } from "../scripts/headers.mjs";

const dist = fileURLToPath(new URL("../dist", import.meta.url));
const headers = readFileSync(join(dist, "_headers"), "utf-8");
const csp = headers.match(/^ {2}Content-Security-Policy: (.+)$/mu)?.[1] ?? "";
const scriptSrc = csp.split("; ").find((directive) => directive.startsWith("script-src ")) ?? "";
const PINNED_SCRIPTS = "149921fae96b5259";

test("every inline script of every page is allowed by its hash", () => {
  const html = readdirSync(dist, { recursive: true }).filter((entry) => entry.endsWith(".html"));
  assert.ok(html.length > 50, `only ${html.length} pages built`);
  for (const entry of html) {
    for (const body of inlineScripts(readFileSync(join(dist, entry), "utf-8"))) {
      assert.ok(scriptSrc.includes(scriptHash(body)), `${entry}: inline script missing from the CSP: ${body.slice(0, 60)}`);
    }
  }
});

/** What in a page's tags could run code the CSP's hashes do not cover. */
function tagProblems(html) {
  const problems = [];
  const page = html.replace(/<script\b(?:"[^"]*"|'[^']*'|[^"'>])*>[\s\S]*?<\/script\s*>/giu, (script) => script.match(START_TAG)[0]);
  for (const [tag] of page.matchAll(START_TAG)) {
    const attributes = tag.replace(/"[^"]*"|'[^']*'/gu, '""');
    if (/\son[a-z]+\s*=/iu.test(attributes)) problems.push(`event handler attribute in ${tag.slice(0, 80)}`);
    if (/\s(?:href|src|action|formaction)\s*=\s*["']?\s*javascript:/iu.test(tag)) problems.push(`javascript: URL in ${tag.slice(0, 80)}`);
    const src = tag.match(/^<script\b(?:"[^"]*"|'[^']*'|[^"'>])*?\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/iu);
    if (src && !/^\/(?!\/)/u.test(src[1] ?? src[2] ?? src[3])) problems.push(`script from another origin: ${tag.slice(0, 80)}`);
  }
  return problems;
}

test("pages hold no script the CSP cannot hash, and only the inline scripts it was checked with", () => {
  const html = readdirSync(dist, { recursive: true }).filter((entry) => entry.endsWith(".html"));
  for (const entry of html) assert.deepEqual(tagProblems(readFileSync(join(dist, entry), "utf-8")), [], entry);
  const hashes = (scriptSrc.match(/'sha256-[^']+'/gu) ?? []).sort();
  const digest = createHash("sha256").update(hashes.join(" ")).digest("hex").slice(0, 16);
  // A Blume upgrade that adds or changes an inline script lands here: before updating the digest, read
  // the new scripts in dist/ and check they run nothing a page or URL can inject into.
  assert.equal(digest, PINNED_SCRIPTS, `the CSP's ${hashes.length} inline script hashes changed (digest ${digest}): read the scripts in dist/ before updating PINNED_SCRIPTS`);
});

test("the tag check sees past a > in a quoted attribute, and any case or quoting of a script", () => {
  for (const html of [
    '<a title="a > b" onclick="run()">x</a>',
    '<a title=\'x>\' href="javascript:run()">x</a>',
    "<script src='//cdn.example.com/a.js'></script>",
    "<script src=//cdn.example.com/a.js></script>",
    '<SCRIPT SRC="https://cdn.example.com/a.js"></SCRIPT>',
    '<script data-x="a>b" src="//cdn.example.com/a.js"></script>',
  ]) {
    assert.equal(tagProblems(html).length, 1, html);
  }
  assert.deepEqual(tagProblems('<a title="a > b" href="/x">x</a><script src="/_astro/a.js"></script><script>if (a > b) run()</script>'), []);
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
<script type="application/json">[]</script><script>run()</script><script type="module">go()</script>
<SCRIPT data-x="a>b">up()</SCRIPT><script src='/b.js'></script>`;
  assert.deepEqual(inlineScripts(html), ["run()", "go()", "up()"]);
});
