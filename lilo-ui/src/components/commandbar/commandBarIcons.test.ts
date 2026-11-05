import assert from "node:assert/strict";
import test from "node:test";

import {
  buildTabFaviconLookup,
  LINE_ICONS,
  resolveResultIcon,
} from "./commandBarIcons";
import { COMMAND_ACTIONS } from "../../lib/inputParser";
import { hostOf } from "../../lib/url";

const FAVICON_COM = "data:image/png;base64,COM";
const FAVICON_ORG = "data:image/png;base64,ORG";

const lookup = buildTabFaviconLookup([
  { id: "t1", url: "https://example.com/lilo/pull/142", faviconDataURL: FAVICON_COM },
  { id: "t2", url: "https://www.example.org/ci", faviconDataURL: FAVICON_ORG },
  { id: "t3", url: "https://example.com/other", faviconDataURL: "data:image/png;base64,OTHER" },
  { id: "t4", url: "https://nofavicon.example", faviconDataURL: undefined },
]);

function result(overrides: {
  kind: string;
  icon?: string;
  url?: string;
  payload?: Record<string, unknown>;
}) {
  return { icon: undefined, url: undefined, payload: {}, ...overrides };
}

test("hostOf parses https, schemeless and strips www.", () => {
  assert.equal(hostOf("https://Example.COM/x"), "example.com");
  assert.equal(hostOf("example.com/x"), "example.com");
  assert.equal(hostOf("https://www.example.org/ci"), "example.org");
  assert.equal(hostOf("not a url"), null);
  assert.equal(hostOf(""), null);
  assert.equal(hostOf(undefined), null);
});

test("lookup: first favicon wins per host, tabs without favicon are skipped", () => {
  assert.equal(lookup.byTabId.get("t1"), FAVICON_COM);
  assert.equal(lookup.byTabId.has("t4"), false);
  assert.equal(lookup.byHost.get("example.com"), FAVICON_COM);
  assert.equal(lookup.byHost.get("example.org"), FAVICON_ORG);
});

test("tab result resolves by tab id first", () => {
  const spec = resolveResultIcon(
    result({ kind: "tab", url: "https://example.com/lilo/pull/142", payload: { tabId: "t3" } }),
    lookup,
  );
  assert.deepEqual(spec, {
    type: "favicon",
    src: "data:image/png;base64,OTHER",
    fallback: "E",
    hue: (spec as { hue: number }).hue,
  });
});

test("bookmark/history/navigate fall back to an open tab's host favicon", () => {
  const spec = resolveResultIcon(
    result({ kind: "history", url: "https://example.org/somewhere/else" }),
    lookup,
  );
  assert.deepEqual(spec, { type: "favicon", src: FAVICON_ORG, fallback: "E", hue: (spec as { hue: number }).hue });
});

test("history without an open tab on its host uses the stored favicon, www. or not", () => {
  const stored = { "site.example": "data:site", "www.other.example": "data:other" };
  const cases = [
    { kind: "history", url: "https://www.site.example/a", stored, src: "data:site", fallback: "S" },
    { kind: "archivedTab", url: "https://other.example/b", stored, src: "data:other", fallback: "O" },
    { kind: "history", url: "https://example.org/c", stored: { "example.org": "data:stale" }, src: FAVICON_ORG, fallback: "E" },
  ];
  for (const { kind, url, stored, src, fallback } of cases) {
    const spec = resolveResultIcon(result({ kind, url }), lookup, stored);
    assert.deepEqual(spec, { type: "favicon", src, fallback, hue: (spec as { hue: number }).hue });
  }
});

test("no favicon for the host gives a letter monogram from the domain", () => {
  const spec = resolveResultIcon(
    result({ kind: "history", url: "https://site.example/q/1" }),
    lookup,
  );
  assert.deepEqual(spec, { type: "letter", letter: "S", hue: (spec as { hue: number }).hue });
});

test("a domain's tile keeps one hue, whatever the page", () => {
  const hue = (url: string) => (resolveResultIcon(result({ kind: "history", url }), lookup) as { hue: number }).hue;
  assert.equal(hue("https://site.example/q/1"), hue("https://www.site.example/other"));
  assert.notEqual(hue("https://site.example/"), hue("https://other.example/"));
});

test("unparsable or missing url gives a '?' letter", () => {
  assert.deepEqual(
    resolveResultIcon(result({ kind: "history", url: "not a url" }), lookup),
    { type: "letter", letter: "?", hue: 0 },
  );
  assert.deepEqual(
    resolveResultIcon(result({ kind: "bookmark" }), lookup),
    { type: "letter", letter: "?", hue: 0 },
  );
});

test("every action draws a line icon", () => {
  for (const action of COMMAND_ACTIONS) {
    assert.deepEqual(
      resolveResultIcon(result({ kind: "action", icon: action.icon }), lookup),
      { type: "line", path: LINE_ICONS[action.icon] },
      action.id,
    );
  }
});

test("a Space keeps its own glyph", () => {
  assert.deepEqual(
    resolveResultIcon(result({ kind: "space", icon: "💼" }), lookup),
    { type: "glyph", glyph: "💼" },
  );
  assert.deepEqual(
    resolveResultIcon(result({ kind: "action" }), lookup),
    { type: "glyph", glyph: "•" },
  );
});
