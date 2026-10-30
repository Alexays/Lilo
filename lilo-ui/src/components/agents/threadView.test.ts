import assert from "node:assert/strict";
import test from "node:test";

import { formatDuration, lineDiff, parseInline, parseMarkdown } from "./threadView";

test("inline markdown splits code, emphasis and links", () => {
  assert.deepEqual(parseInline("Run `npm test` then **check** the *logs* at https://example.com/a."), [
    { type: "text", text: "Run " },
    { type: "code", text: "npm test" },
    { type: "text", text: " then " },
    { type: "strong", text: "check" },
    { type: "text", text: " the " },
    { type: "em", text: "logs" },
    { type: "text", text: " at " },
    { type: "link", text: "https://example.com/a", href: "https://example.com/a" },
    { type: "text", text: "." },
  ]);
});

test("identifiers with underscores stay text, unsafe link targets are not links", () => {
  assert.deepEqual(parseInline("set return_to_path"), [{ type: "text", text: "set return_to_path" }]);
  assert.deepEqual(parseInline("[docs](javascript:alert)"), [{ type: "text", text: "docs" }]);
  assert.deepEqual(parseInline("[docs](https://example.com)"), [{ type: "link", text: "docs", href: "https://example.com" }]);
});

test("blocks: paragraphs, headings, lists, quotes and fenced code", () => {
  const blocks = parseMarkdown("# Fix\n\nFirst line\nsecond line\n\n- one\n- two\n  wrapped\n1. first\n> quoted\n```ts\nconst a = 1;\n```\nafter");
  assert.deepEqual(blocks.map((block) => block.type), ["heading", "p", "list", "list", "quote", "code", "p"]);
  assert.deepEqual(blocks[1], { type: "p", inline: [{ type: "text", text: "First line\nsecond line" }] });
  assert.deepEqual(blocks[2], {
    type: "list",
    ordered: false,
    items: [[{ type: "text", text: "one" }], [{ type: "text", text: "two wrapped" }]],
  });
  assert.deepEqual(blocks[5], { type: "code", lang: "ts", text: "const a = 1;" });
});

test("an unclosed fence runs to the end while the message streams", () => {
  assert.deepEqual(parseMarkdown("Here:\n```\nline 1\nline 2"), [
    { type: "p", inline: [{ type: "text", text: "Here:" }] },
    { type: "code", lang: "", text: "line 1\nline 2" },
  ]);
});

test("line diff keeps the changed span with its context", () => {
  const before = "a\nb\nc\nd\ne\nf\ng\nh\n";
  const after = "a\nb\nc\nd\nE\nf\ng\nh\n";
  assert.deepEqual(lineDiff(before, after, 1), [
    { type: "context", line: 4, text: "d" },
    { type: "removed", line: 5, text: "e" },
    { type: "added", line: 5, text: "E" },
    { type: "context", line: 6, text: "f" },
  ]);
});

test("a new file is all added lines", () => {
  assert.deepEqual(lineDiff(null, "x\ny"), [
    { type: "added", line: 1, text: "x" },
    { type: "added", line: 2, text: "y" },
  ]);
});

test("bare file paths become path chips, URLs and prose stay as they are", () => {
  assert.deepEqual(parseInline("See src/auth/session.ts:12, then ./lib/a.test.ts."), [
    { type: "text", text: "See " },
    { type: "path", text: "src/auth/session.ts:12" },
    { type: "text", text: ", then " },
    { type: "path", text: "./lib/a.test.ts" },
    { type: "text", text: "." },
  ]);
  assert.deepEqual(parseInline("and/or 1/2.5 at https://example.com/a/b.ts"), [
    { type: "text", text: "and/or 1/2.5 at " },
    { type: "link", text: "https://example.com/a/b.ts", href: "https://example.com/a/b.ts" },
  ]);
});

test("durations read in whole seconds, then minutes, then hours", () => {
  assert.deepEqual([formatDuration(400), formatDuration(42_300), formatDuration(65_000), formatDuration(7_380_000)], [
    "0s",
    "42s",
    "1m 05s",
    "2h 03m",
  ]);
});
