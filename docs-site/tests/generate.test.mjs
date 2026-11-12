// Runs the generator on the real sources, and its readers on small snippets that must fail loudly.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import {
  checkToolCount,
  compatibilityPartials,
  errorReport,
  loadSettings,
  mcpPartial,
  parseShortcuts,
  parseTools,
  partials,
  read,
  settingsPartial,
  SOURCES,
  SwiftReader,
} from "../scripts/generate.mjs";

const output = await partials();
const swift = read(SOURCES.shortcuts);
const catalogs = { en: JSON.parse(read(SOURCES.catalog("en"))), fr: JSON.parse(read(SOURCES.catalog("fr"))) };
const tools = SOURCES.tools.map((file) => parseTools(read(file), file));
const byName = Object.fromEntries(tools.flatMap((file) => file.tools).map((tool) => [tool.name, tool]));
const summaries = JSON.parse(read(SOURCES.summaries));
const rows = (markdown) => markdown.split("\n").filter((line) => line.startsWith("| ") && !line.startsWith("| ---"));

test("every shortcut action is read, the two numbered families included", () => {
  const actions = parseShortcuts(swift);
  // Literal entries start their line; each `(1...9).map` family adds nine.
  assert.equal(actions.length, swift.match(/^\s*Action\("/gmu).length + 18);
  assert.equal(new Set(actions.map((action) => action.id)).size, actions.length);
  assert.ok(actions.some((action) => action.id === "space.select9"));
  assert.ok(actions.some((action) => action.id === "tab.select9"));
});

test("shortcuts render as menus show them, in both locales", () => {
  const en = output["content/reference/_generated/shortcuts.md"];
  const fr = output["content/fr/reference/_generated/shortcuts.md"];
  assert.match(en, /^\| New Tab \| <kbd>⌘T<\/kbd> \|$/mu);
  assert.match(en, /^\| Last Tab \| <kbd>⌘9<\/kbd> \|$/mu);
  assert.match(en, /^\| Space 3 \| <kbd>⌃3<\/kbd> \|$/mu);
  assert.match(en, /^\| Clear Browsing Data… \| <kbd>⇧⌘⌫<\/kbd> \|$/mu);
  assert.match(en, /^\| Open File… \| — \|$/mu);
  assert.match(fr, /^\| Nouvel onglet \| <kbd>⌘T<\/kbd> \|$/mu);
  assert.equal(rows(fr).length, rows(en).length);
});

test("every setting is listed once, in both locales", async () => {
  const model = await import(`../../${SOURCES.settings}`);
  for (const locale of ["en", "fr"]) {
    const markdown = output[`content/${locale === "fr" ? "fr/" : ""}reference/_generated/settings.md`];
    const settingRows = rows(markdown).filter((row) => !/^\| (Setting|Réglage) \|/u.test(row));
    assert.equal(settingRows.length, model.SETTINGS.length, locale);
    for (const setting of model.SETTINGS) {
      const title = catalogs[locale].settings.items[setting.id].title.replace("{version}", "{{version}}");
      assert.ok(settingRows.some((row) => row.startsWith(`| ${title} |`)), `${locale}: ${setting.id}`);
    }
  }
  assert.match(output["content/reference/_generated/settings.md"], /^\| Block ads and trackers \| .+ \| On \|$/mu);
});

test("every tool is read with its parameters", () => {
  const declared = SOURCES.tools.reduce((count, file) => count + read(file).match(/^\s*(?:AgentTools\.)?tool\("/gmu).length, 0);
  assert.equal(Object.keys(byName).length, declared);
  assert.equal(declared, 33);
  assert.deepEqual(byName.navigate.required, ["url", "tabId"]);
  assert.deepEqual(byName.read_page.properties.filter.enum, ["interactive", "all"]);
  assert.deepEqual(byName.browser_batch.properties.actions.items.required, ["name", "input"]);
  const markdown = output["content/reference/_generated/mcp-tools.md"];
  assert.match(markdown, /^\| `filter` \| `string`: `interactive`, `all` \| no \| .+ \|$/mu);
  assert.match(markdown, /^\| `actions\[\]\.name` \| `string` \| yes \|  \|$/mu);
  assert.match(markdown, /^\| `colorScheme` \| `string` or `null`: `light`, `dark`, `null` \| no \|/mu);
  // Markdown syntax in a description stays text: `^…^` would be superscript, `{` an MDX expression.
  assert.match(markdown, /\\\{operationName: "\\\^GetUser\$"\\\}/u);
});

test("the generator is deterministic and leaves the translated French partials alone", async () => {
  assert.deepEqual(await partials(), output);
  for (const name of ["mcp-tools", "extension-compatibility", "web-compatibility"]) {
    assert.ok(!Object.hasOwn(output, `content/fr/reference/_generated/${name}.md`), name);
  }
});

test("compatibility sections keep their anchors and links across the two pages", () => {
  const web = output["content/reference/_generated/web-compatibility.md"];
  const extensions = output["content/reference/_generated/extension-compatibility.md"];
  assert.match(extensions, /^## Chrome extensions \[#chrome-extensions\]$/mu);
  assert.doesNotMatch(extensions, /^## Web APIs/mu);
  assert.match(web, /^## Known Limitations .+$/mu);
  assert.match(extensions, /\]\(\/reference\/web-compatibility#icloud-passwords-extension\)/u);
  assert.match(extensions, /\]\(https:\/\/github\.com\/Alexays\/Lilo\/blob\/main\/docs\/ARCHITECTURE\.md#extension-architecture\)/u);
});

test("every compatibility section is published once, matched by its exact heading", () => {
  const pages = { "/a": ["Web APIs"] };
  assert.throws(() => compatibilityPartials("## Web APIs\n\nx\n\n## Site quirks\n\ny\n", pages), /COMPATIBILITY\.md: the section "## Site quirks" is on no docs page: .+generate\.mjs/u);
  assert.throws(() => compatibilityPartials("## Web APIs for extensions\n\nx\n", pages), /no "## Web APIs" heading/u);
  const fenced = compatibilityPartials("## Web APIs\n\n```sh\n## not a heading\n```\n\nAfter the fence.\n", pages)["/a"];
  assert.match(fenced, /```sh\n## not a heading\n```\n\nAfter the fence\./u);
});

test("the Swift reader reads string blocks and nested dictionaries", () => {
  const block = new SwiftReader(['"""', "        First line \\", "        continued, \\(no) \\\"quoted\\\".", "        Second line.", '        """'].join("\n"), "x.swift");
  assert.throws(() => block.value(), /x\.swift:\d+: string interpolation/u);
  const text = new SwiftReader(['"""', "        First line \\", '        continued "quoted".', "        Second line.", '        """'].join("\n"), "x.swift");
  assert.equal(text.value(), 'First line continued "quoted".\nSecond line.');
  const nested = new SwiftReader('["a": ["type": "array", "items": ["type": "object", "properties": ["b": ["type": "string"]], "required": ["b"]]], "c": [:]]', "x.swift");
  assert.deepEqual(nested.value(), { a: { type: "array", items: { type: "object", properties: { b: { type: "string" } }, required: ["b"] } }, c: {} });
});

test("the Swift reader throws on anything else", () => {
  assert.throws(() => new SwiftReader('["a": prop("string", description)]', "x.swift").value(), /x\.swift:1: unexpected expression/u);
  assert.throws(() => new SwiftReader('"\\(name)"', "x.swift").value(), /string interpolation/u);
});

test("the generator names the file and the item it cannot read", () => {
  const renamed = swift.replace('Action("tab.new", "New Tab", "File", ["⌘t"])', 'Action("tab.new", title, "File", ["⌘t"])');
  assert.throws(() => parseShortcuts(renamed), /KeyboardShortcuts\.swift: cannot read this shortcut entry: Action\("tab\.new", title/u);
  const file = SOURCES.tools[0];
  const odd = read(file).replace('"filter": ["type": "string", "enum"', '"filter": ["kind": "string", "enum"');
  assert.throws(() => parseTools(odd, file), /AgentTools\.swift: read_page\.filter has a schema key the reference does not show: kind/u);
  const { [Object.keys(summaries)[0]]: _, ...missing } = summaries;
  assert.throws(() => mcpPartial(tools, missing), /mcp-tools\.json: no summary for the tool "tabs_context_mcp"/u);
  assert.throws(() => mcpPartial(tools, { ...summaries, open_window: "Opens." }), /summary for "open_window", a tool no Swift file defines/u);
  assert.throws(() => compatibilityPartials("## Web APIs\n", { "/x": ["Chrome extensions"] }), /COMPATIBILITY\.md: no "## Chrome extensions" heading/u);
});

test("a tool list the reader would only partly read fails", () => {
  const [file, source] = [SOURCES.tools[2], read(SOURCES.tools[2])];
  const end = source.indexOf("\n    ]\n", source.indexOf("static let definitions"));
  for (const tail of ["] + experimentalDefinitions", "].filter { _ in true }", "]\n    .filter { _ in true }", "]\n        + experimentalDefinitions", "] // done\n    + experimentalDefinitions", "]\n    // a comment\n\n    .filter { _ in true }"]) {
    const changed = `${source.slice(0, end)}\n    ${tail}\n${source.slice(end + 7)}`;
    assert.throws(() => parseTools(changed, file), /AgentDevTools\.swift:\d+: a tool list must end at its closing \]/u);
  }
  const [main, mainSource] = [SOURCES.tools[0], read(SOURCES.tools[0])];
  const composed = "tabAndPageDefinitions + AgentInteractionTools.definitions + AgentDevTools.definitions";
  assert.ok(mainSource.includes(composed));
  const declaration = `static let definitions: [[String: Any]] = ${composed}`;
  assert.ok(mainSource.includes(declaration));
  for (const changed of [
    `${declaration} + [["name": "extra", "description": "x"]]`,
    `${declaration}\n        + [["name": "extra"]]`,
    `${declaration}\n        // more\n        + extraDefinitions`,
    `${declaration}.filter { _ in true }`,
    `static let definitions = ${composed} + extraDefinitions`,
    `static var definitions: [[String: Any]] { ${composed} }`,
  ]) {
    assert.throws(() => parseTools(mainSource.replace(declaration, changed), main), /AgentTools\.swift: definitions is not a `\[\[String: Any\]\]` literal nor .+ would be missed/u);
  }
  const sources = Object.fromEntries(SOURCES.tools.map((name) => [name, read(name)]));
  assert.doesNotThrow(() => checkToolCount(tools, sources));
  const more = { ...sources, "Lilo/Agent/AgentMoreTools.swift": 'enum AgentMoreTools {\n    static let definitions: [ToolDefinition] = [\n        AgentTools.tool("new_tool", "x", [:]),\n    ]\n}\n' };
  assert.throws(() => checkToolCount(tools, more), /Lilo\/Agent: 34 tool\(…\) definitions are in the code but the generator read 33 .+SOURCES\.tools/u);
  // Mid-line and one-line lists count too; a tool named in a description's text does not.
  const inline = { ...sources, "Lilo/Agent/AgentMoreTools.swift": 'let more = [Self.tool("a", "Calls tool(\\"b\\", x).", [:]), tool("c", """\n    Calls tool("d").\n    """, [:])]\n' };
  assert.throws(() => checkToolCount(tools, inline), /Lilo\/Agent: 35 tool\(…\) definitions are in the code but the generator read 33/u);
  const twice = source.replace("static let definitions: [[String: Any]] = [", 'static let definitions: [[String: Any]] = [\n        AgentTools.tool("navigate", "dup", [:]),');
  assert.throws(() => mcpPartial([tools[0], tools[1], parseTools(twice, file)], summaries), /two tools are named "navigate"/u);
});

test("a shortcut list changed after its literal fails", () => {
  for (const tail of ["\n    .filter { $0.id != \"app.quit\" }\n", "\n        + extraActions\n", "\n    // more\n    + extraActions\n"]) {
    const changed = swift.replace(/\n {4}\]\n/u, `\n    ]${tail}`);
    assert.notEqual(changed, swift);
    assert.throws(() => parseShortcuts(changed), /KeyboardShortcuts\.swift: the actions list is changed after its literal/u);
  }
});

test("a compatibility heading written twice fails instead of dropping the second section", () => {
  assert.throws(() => compatibilityPartials("## Web APIs\n\nx\n\n## Web APIs\n\ny\n", { "/a": ["Web APIs"] }), /COMPATIBILITY\.md: two "## Web APIs" sections/u);
});

test("an enum value or parameter name with a pipe stays in its cell", () => {
  const file = SOURCES.tools[0];
  const odd = read(file).replace('"enum": ["interactive", "all"]', '"enum": ["inter|active", "all"]').replace('"filter": [', '"fil|ter": [');
  const markdown = mcpPartial([parseTools(odd, file), tools[1], tools[2]], summaries);
  assert.match(markdown, /^\| `fil\\\|ter` \| `string`: `inter\\\|active`, `all` \| no \|/mu);
});

test("a failure tells an app contributor what failed and what to do", async () => {
  const dir = mkdtempSync(join(tmpdir(), "docs-generate-"));
  const model = join(dir, "model.ts");
  writeFileSync(model, "export enum Mode { A }\n");
  await assert.rejects(loadSettings(model), new RegExp(`${SOURCES.settings}: plain Node cannot load it .+type-only imports, no enum`, "u"));
  rmSync(dir, { recursive: true });
  assert.match(errorReport(new Error("x.swift: odd")), /^docs-site\/scripts\/generate\.mjs, .+ failed on x\.swift: odd\n.+make docs-check/u);
  const { navigate: _, ...renamed } = summaries;
  assert.throws(() => mcpPartial(tools, renamed), /no summary for the tool "navigate" \(Lilo\/Agent\/AgentTools\.swift\): add one to docs-site\/scripts\/mcp-tools\.json/u);
});

test("a shortcut title or setting without a catalog string fails", async () => {
  const { shortcutsPartial } = await import("../scripts/generate.mjs");
  const actions = parseShortcuts(swift.replace('"New Tab", "File"', '"New Tab Now", "File"'));
  assert.throws(() => shortcutsPartial(actions, catalogs.fr, "fr"), /fr\.json: no "native" string for the shortcut title or category "New Tab Now"/u);
  const model = await import(`../../${SOURCES.settings}`);
  const items = { ...catalogs.en.settings.items, theme: { title: "Theme" } };
  const catalog = { ...catalogs.en, settings: { ...catalogs.en.settings, items } };
  assert.throws(() => settingsPartial(model, catalog, "en"), /en\.json: no string "settings\.items\.theme\.description"/u);
});
