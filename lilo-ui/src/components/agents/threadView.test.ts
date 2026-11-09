import assert from "node:assert/strict";
import test from "node:test";

import { codeTokens, formatDuration, imageSource, lineDiff, parseInline, parseMarkdown, type MarkdownParse } from "./threadView";

test("inline markdown splits code, emphasis and links", () => {
  assert.deepEqual(parseInline("Run `npm test` then **check** the *logs* at https://example.com/a."), [
    { type: "text", text: "Run " },
    { type: "code", text: "npm test" },
    { type: "text", text: " then " },
    { type: "strong", inline: [{ type: "text", text: "check" }] },
    { type: "text", text: " the " },
    { type: "em", inline: [{ type: "text", text: "logs" }] },
    { type: "text", text: " at " },
    { type: "link", text: "https://example.com/a", href: "https://example.com/a" },
    { type: "text", text: "." },
  ]);
});

test("emphasis holds code and links", () => {
  assert.deepEqual(parseInline("**`index.html`:** see *[docs](https://example.com)*"), [
    { type: "strong", inline: [{ type: "code", text: "index.html" }, { type: "text", text: ":" }] },
    { type: "text", text: " see " },
    { type: "em", inline: [{ type: "link", text: "docs", href: "https://example.com" }] },
  ]);
});

test("hex colours in prose, never issue numbers", () => {
  assert.deepEqual(parseInline("Use #5B5BD6, not #123456 or #fed"), [
    { type: "text", text: "Use " },
    { type: "color", text: "#5B5BD6" },
    { type: "text", text: ", not #123456 or #fed" },
  ]);
});

test("identifiers with underscores stay text, unsafe link targets are not links", () => {
  assert.deepEqual(parseInline("set return_to_path"), [{ type: "text", text: "set return_to_path" }]);
  assert.deepEqual(parseInline("[docs](javascript:alert)"), [{ type: "text", text: "docs" }]);
  assert.deepEqual(parseInline("[docs](https://example.com)"), [{ type: "link", text: "docs", href: "https://example.com" }]);
});

test("blocks: paragraphs, headings, lists, quotes and fenced code", () => {
  const { blocks } = parseMarkdown("# Fix\n\nFirst line\nsecond line\n\n- one\n- two\n  wrapped\n1. first\n> quoted\n```ts\nconst a = 1;\n```\nafter");
  assert.deepEqual(blocks.map((block) => block.type), ["heading", "p", "list", "list", "quote", "code", "p"]);
  assert.deepEqual(blocks[1], { type: "p", inline: [{ type: "text", text: "First line\nsecond line" }] });
  assert.deepEqual(blocks[2], {
    type: "list",
    ordered: false,
    items: [
      { inline: [{ type: "text", text: "one" }], lists: [] },
      { inline: [{ type: "text", text: "two wrapped" }], lists: [] },
    ],
  });
  assert.deepEqual(blocks[5], { type: "code", lang: "ts", text: "const a = 1;" });
});

test("a table is a header and a delimiter row, its body running to a line with no pipe", () => {
  const { blocks } = parseMarkdown("| Name | Size |\n|:--|--:|\n| `a\\|b` | 2 |\n| c |\nafter");
  assert.deepEqual(blocks, [
    {
      type: "table",
      align: ["left", "right"],
      head: [[{ type: "text", text: "Name" }], [{ type: "text", text: "Size" }]],
      rows: [[[{ type: "code", text: "a|b" }], [{ type: "text", text: "2" }]], [[{ type: "text", text: "c" }]]],
    },
    { type: "p", inline: [{ type: "text", text: "after" }] },
  ]);
  // Before its delimiter row arrives, a streaming header is a paragraph.
  assert.equal(parseMarkdown("| Name | Size |").blocks[0].type, "p");
});

test("an unclosed fence runs to the end while the message streams", () => {
  assert.deepEqual(parseMarkdown("Here:\n```\nline 1\nline 2").blocks, [
    { type: "p", inline: [{ type: "text", text: "Here:" }] },
    { type: "code", lang: "", text: "line 1\nline 2" },
  ]);
});

test("a message parsed chunk by chunk gives the blocks of one parse, and keeps the settled ones", () => {
  const text = "# Plan\n\nFirst *step*\n\n```ts\nconst a = 1;\n\nconst b = 2;\n```\n\n- one\n  wrapped\n\n> quoted\n\n \nlast";
  let parsed: MarkdownParse | undefined;
  for (let length = 1; length <= text.length; length += 3) {
    const previous = parsed;
    parsed = parseMarkdown(text.slice(0, length), previous);
    assert.deepEqual(parsed.blocks, parseMarkdown(text.slice(0, length)).blocks);
    for (let i = 0; i < (previous?.settled ?? 0); i++) assert.equal(parsed.blocks[i], previous?.blocks[i]);
  }
  assert.deepEqual(parseMarkdown(text, parsed).blocks, parseMarkdown(text).blocks);
  assert.deepEqual(parseMarkdown("Other", parsed).blocks, [{ type: "p", inline: [{ type: "text", text: "Other" }] }]);
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
  assert.deepEqual(parseInline("Title (faq.html:6), at 10:30 on v1.2"), [
    { type: "text", text: "Title (" },
    { type: "path", text: "faq.html:6" },
    { type: "text", text: "), at 10:30 on v1.2" },
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

test("markdown images parse before links", () => {
  assert.deepEqual(parseInline("See ![the chart](out/chart.png) and [docs](https://example.com)"), [
    { type: "text", text: "See " },
    { type: "image", alt: "the chart", src: "out/chart.png" },
    { type: "text", text: " and " },
    { type: "link", text: "docs", href: "https://example.com" },
  ]);
});

test("image sources: local files go through Lilo, remote ones stay links", () => {
  const local = (path: string) => ({ type: "image", src: `lilo-chrome://ui/conversation-file/${encodeURIComponent(path)}` });
  assert.deepEqual(imageSource("./out/a b.png", "/p/app"), local("/p/app/out/a b.png"));
  assert.deepEqual(imageSource("file:///p/app/shot.JPG", "/p/app"), local("/p/app/shot.JPG"));
  assert.deepEqual(imageSource("/p/app/logo.svg?v=2", ""), local("/p/app/logo.svg"));
  assert.deepEqual(imageSource("data:image/png;base64,AAAA", ""), { type: "image", src: "data:image/png;base64,AAAA" });
  assert.deepEqual(imageSource("https://example.com/a.png", ""), { type: "remote", href: "https://example.com/a.png", host: "example.com" });
  assert.deepEqual([imageSource("notes.md", "/p"), imageSource("a.png", ""), imageSource("javascript:alert(1)", "/p")], [null, null, null]);
});

test("code tokens color keywords, strings, comments, numbers and types, and leave unknown languages plain", () => {
  const kinds = (code: string, lang: string) => codeTokens(code, lang)?.filter((token) => token.kind).map((token) => `${token.kind}:${token.text}`);
  assert.deepEqual(kinds('const map = new Map<HTMLElement>(MAX); // "note"\nlet n = 0x1F + 2.5e3;', "ts"), [
    "keyword:const", "keyword:new", "type:Map", "type:HTMLElement", 'comment:// "note"', "keyword:let", "number:0x1F", "number:2.5e3",
  ]);
  assert.deepEqual(kinds("fn f<'a>(s: &'a str) -> String { \"x\".into() }", "rust"), ["keyword:fn", "type:String", 'string:"x"']);
  assert.deepEqual(kinds("echo $# items # count\nif [ -f a ]; then", "sh"), ["comment:# count", "keyword:if", "keyword:then"]);
  assert.deepEqual(kinds("SELECT id FROM users WHERE id = 1", "sql"), ["keyword:SELECT", "keyword:FROM", "keyword:WHERE", "number:1"]);
  assert.equal(codeTokens("<p>hi</p>", "html"), null);
  assert.equal(codeTokens("a\n  b", "ts")?.map((token) => token.text).join(""), "a\n  b");
});

test("a list item opening on a box is a task, checked or not", () => {
  const { blocks } = parseMarkdown("- [ ] write `a.ts`\n- [x] ship\n- [link](https://example.com)");
  assert.deepEqual(blocks[0], {
    type: "list",
    ordered: false,
    items: [
      { inline: [{ type: "task", checked: false }, { type: "text", text: "write " }, { type: "code", text: "a.ts" }], lists: [] },
      { inline: [{ type: "task", checked: true }, { type: "text", text: "ship" }], lists: [] },
      { inline: [{ type: "link", text: "link", href: "https://example.com" }], lists: [] },
    ],
  });
});

test("an indented item nests under the one above it, of either kind, and the outer list carries on after it", () => {
  const { blocks } = parseMarkdown("1. Frontend\n   - UI\n     wrapped\n   - State\n2. Backend\n\t* API\n- after");
  const item = (text: string, lists: unknown[] = []) => ({ inline: [{ type: "text", text }], lists });
  assert.deepEqual(blocks, [
    {
      type: "list",
      ordered: true,
      items: [
        item("Frontend", [{ type: "list", ordered: false, items: [item("UI wrapped"), item("State")] }]),
        item("Backend", [{ type: "list", ordered: false, items: [item("API")] }]),
      ],
    },
    { type: "list", ordered: false, items: [item("after")] },
  ]);
});

test("an ordered list starts at its first number, so steps split by code blocks count on", () => {
  const { blocks } = parseMarkdown("1. Create\n```bash\nnpm create vite\n```\n2. Install\n- 0. zero");
  assert.deepEqual(
    blocks.map((block) => (block.type === "list" ? [block.ordered, block.start] : block.type)),
    [[true, undefined], "code", [true, 2], [false, undefined]],
  );
});

test("a line of three dashes, stars or underscores is a rule; ~~text~~ is struck through", () => {
  const { blocks } = parseMarkdown("Intro\n---\n* * *\n___\nWas ~~**old**~~ now\n- item");
  assert.deepEqual(blocks.slice(0, 4), [
    { type: "p", inline: [{ type: "text", text: "Intro" }] },
    { type: "rule" },
    { type: "rule" },
    { type: "rule" },
  ]);
  assert.deepEqual(blocks[4], {
    type: "p",
    inline: [
      { type: "text", text: "Was " },
      { type: "del", inline: [{ type: "strong", inline: [{ type: "text", text: "old" }] }] },
      { type: "text", text: " now" },
    ],
  });
  assert.equal(blocks[5].type, "list");
});

test("a fence indented into a list item takes its indent off its lines, never more, and nests under it", () => {
  const { blocks } = parseMarkdown("1. Add\n   ```bash\n   git remote -v\n     nested\n  short\n   ```\n2. Done");
  assert.deepEqual(blocks[1], { type: "code", lang: "bash", text: "git remote -v\n  nested\nshort", nested: true });
  assert.deepEqual(blocks[2].type === "list" && blocks[2].start, 2);
  assert.deepEqual(parseMarkdown("Intro\n   ```\nx\n```").blocks[1], { type: "code", lang: "", text: "x" });
});

test("a <kbd> tag is a key, never raw markup", () => {
  assert.deepEqual(parseInline("Press <kbd>Cmd</kbd>+<kbd>K</kbd>"), [
    { type: "text", text: "Press " },
    { type: "kbd", text: "Cmd" },
    { type: "text", text: "+" },
    { type: "kbd", text: "K" },
  ]);
});

test("a footnote reference is a ref, its definition line a note", () => {
  const { blocks } = parseMarkdown("Attached here[^1].\n\n[^1]: The **source**.");
  assert.deepEqual(blocks, [
    { type: "p", inline: [{ type: "text", text: "Attached here" }, { type: "ref", text: "1" }, { type: "text", text: "." }] },
    { type: "note", id: "1", inline: [{ type: "text", text: "The " }, { type: "strong", inline: [{ type: "text", text: "source" }] }, { type: "text", text: "." }] },
  ]);
});
