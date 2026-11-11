// Runs on the build `make docs-test` makes first.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const docs = fileURLToPath(new URL("..", import.meta.url));
const dist = join(docs, "dist");
const content = join(docs, "content");
const SITE = "https://docs.getlilo.app";

/** The route of every English page: `content/guides/split-view.mdx` is `/guides/split-view`, the index `/`. */
const routes = readdirSync(content, { recursive: true })
  .filter((entry) => /\.mdx?$/u.test(entry) && !entry.startsWith("fr/") && !entry.split("/").some((part) => part.startsWith("_")))
  .map((entry) => `/${entry.replace(/\.mdx?$/u, "").replace(/(^|\/)index$/u, "")}`)
  .sort();
const french = (route) => (route === "/" ? "/fr" : `/fr${route}`);
const url = (route) => (route === "/" ? `${SITE}/` : `${SITE}${route}`);
const page = (route) => readFileSync(join(dist, route, "index.html"), "utf-8");

test("the sitemap lists every English page with its French alternate", () => {
  const sitemap = readFileSync(join(dist, "sitemap.xml"), "utf-8");
  for (const route of routes) {
    const entry = sitemap.match(new RegExp(`<url><loc>${url(route)}</loc>(.*?)</url>`, "u"))?.[1];
    assert.ok(entry, `${route} missing from sitemap.xml`);
    assert.ok(entry.includes(`hreflang="fr" href="${url(french(route))}"`), `${route} has no French alternate in sitemap.xml`);
  }
});

test("every page has one h1, a canonical on the site and its language alternates", () => {
  for (const route of routes.flatMap((route) => [route, french(route)])) {
    const html = page(route);
    assert.equal(html.match(/<h1[\s>]/gu)?.length, 1, `${route}: not exactly one <h1>`);
    assert.ok(html.includes(`<link rel="canonical" href="${url(route)}">`), `${route}: canonical`);
    for (const lang of ["en", "fr", "x-default"]) {
      assert.match(html, new RegExp(`<link href="${SITE}[^"]*" hreflang="${lang}" rel="alternate">`, "u"), `${route}: hreflang ${lang}`);
    }
  }
});

test("agents get llms.txt and a Markdown copy of each page", () => {
  assert.match(readFileSync(join(dist, "llms.txt"), "utf-8"), /getlilo\.app\/llms\.txt/u);
  for (const route of routes.filter((route) => route !== "/")) {
    assert.ok(existsSync(join(dist, `${route}.md`)), `${route}.md missing`);
  }
});

test("no built file points at a development server", () => {
  for (const entry of readdirSync(dist, { recursive: true })) {
    if (/\.(html|md|txt|xml|json)$/u.test(entry)) {
      assert.doesNotMatch(readFileSync(join(dist, entry), "utf-8"), /localhost|127\.0\.0\.1/u, relative(dist, join(dist, entry)));
    }
  }
});
