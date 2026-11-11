// Writes the reference partials that the reference pages include, from the files that define them,
// so the tables cannot drift from the app. Runs before every Blume command. Its output must be
// deterministic: the translation ledger compares a hash of each English partial. It never writes the
// French partials that `blume translate` produces (MCP tools, compatibility). Anything it does not
// understand in a source throws, naming the file and the item: a partial table is worse than none.
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const docs = fileURLToPath(new URL("..", import.meta.url));
const repo = fileURLToPath(new URL("../..", import.meta.url));
export const read = (path) => readFileSync(`${repo}${path}`, "utf-8");

export const SOURCES = {
  shortcuts: "Lilo/App/KeyboardShortcuts.swift",
  settings: "lilo-ui/src/components/settings/settingsPanelModel.ts",
  tools: ["Lilo/Agent/AgentTools.swift", "Lilo/Agent/AgentInteractionTools.swift", "Lilo/Agent/AgentDevTools.swift"],
  summaries: "docs-site/scripts/mcp-tools.json",
  compatibility: "COMPATIBILITY.md",
  catalog: (locale) => `lilo-ui/src/lib/i18n/locales/${locale}.json`,
};

const fail = (file, message) => {
  throw new Error(`${file}: ${message}`);
};

const LABELS = {
  en: { action: "Action", shortcut: "Shortcut", or: " or ", none: "—", setting: "Setting", description: "Description", default: "Default", on: "On", off: "Off" },
  fr: { action: "Action", shortcut: "Raccourci", or: " ou ", none: "—", setting: "Réglage", description: "Description", default: "Par défaut", on: "Activé", off: "Désactivé" },
};

/** Text for a Markdown table cell read as MDX: code spans kept, everything else literal. */
export function cell(text) {
  return String(text)
    .replace(/\s*\n\s*/gu, " ")
    .split(/(`[^`]*`)/u)
    .map((part, index) => (index % 2 ? part.replaceAll("|", "\\|") : part.replace(/[\\`*_{}[\]<>|~^]/gu, "\\$&")))
    .join("");
}

/** Whether a Swift statement ends at `at`: no operator or method call carries the expression on to the next line. */
export const endsAt = (source, at) => /[ \t]*(?:\/\/[^\n]*)?\n(?![ \t\n]*(?:[.+\-*?&|]|\/[^/*]))/uy.test(source.slice(at));

const table = (head, rows) =>
  [`| ${head.join(" | ")} |`, `| ${head.map(() => "---").join(" | ")} |`, ...rows.map((row) => `| ${row.join(" | ")} |`)].join("\n");

const anchor = (text) => text.replace(/([a-z])([A-Z])/gu, "$1-$2").toLowerCase().replace(/[^a-z0-9]+/gu, "-");

// MARK: Keyboard shortcuts

const ACTION = String.raw`Action\("([^"\\]+)", "([^"\\]+)", "([^"\\]+)"(?:, \[((?:"[^"\\]*"(?:, )?)*)\])?\)`;
const FAMILY = String.raw`\(1\.\.\.9\)\.map \{ Action\("([\w.]+)\\\(\$0\)", unsafe (.+?), "([^"\\]+)", \["([⌃⌥⇧⌘]+)\\\(\$0\)"\]\) \}`;
const FAMILY_TITLE = /^(?:\$0 == (\d) \? "([^"\\]+)" : )?String\(format: "([^"\\]+)"\.localized, \$0\)$/u;
const KEY_GLYPHS = { left: "←", right: "→", down: "↓", up: "↑", tab: "⇥", return: "↩", escape: "⎋", delete: "⌫", forwarddelete: "⌦", home: "↖", end: "↘", pageup: "⇞", pagedown: "⇟" };

/** Every action of `KeyboardShortcuts.actions` in source order: `title` is its catalog key, `count` fills its `%d`. */
export function parseShortcuts(source, file = SOURCES.shortcuts) {
  const start = source.indexOf("static let actions: [Action] = [");
  const end = source.indexOf("\n    ]\n", start);
  if (start === -1 || end === -1) fail(file, "no `static let actions: [Action] = [ … ]` block");
  if (!endsAt(source, end + "\n    ]".length)) fail(file, "the actions list is changed after its literal (`.filter`, `+ more`…), which the reference cannot follow");
  const body = source.slice(start + "static let actions: [Action] = [".length, end).replace(/^\s*\/\/.*$/gmu, "");
  const actions = [];
  const leftover = body.replace(new RegExp(`${ACTION}|${FAMILY}`, "gu"), (_, id, title, category, defaults, family, expression, familyCategory, modifiers) => {
    if (id) {
      actions.push({ id, title, category, defaults: [...(defaults ?? "").matchAll(/"([^"\\]*)"/gu)].map((match) => match[1]) });
      return "";
    }
    const parsed = expression.match(FAMILY_TITLE);
    if (!parsed) fail(file, `cannot read the title of the ${family}N family: ${expression}`);
    for (let count = 1; count <= 9; count += 1) {
      const last = parsed[1] && Number(parsed[1]) === count;
      actions.push({ id: `${family}${count}`, title: last ? parsed[2] : parsed[3], count: last ? undefined : count, category: familyCategory, defaults: [`${modifiers}${count}`] });
    }
    return "";
  });
  const unread = leftover.split("\n").find((line) => /[^\s[\]+,]/u.test(line));
  if (unread) fail(file, `cannot read this shortcut entry: ${unread.trim().slice(0, 120)}`);
  if (actions.length < 100) fail(file, `only ${actions.length} actions read, expected at least 100`);
  return actions;
}

/** A combo as macOS menus show it ("⇧⌘T", "⌃⇥"), as `KeyboardShortcuts.display` does. */
export function displayCombo(combo, file = SOURCES.shortcuts) {
  const [, modifiers, key] = combo.match(/^([⌃⌥⇧⌘]*)(.+)$/u) ?? fail(file, `empty combo`);
  if ([...modifiers].sort((a, b) => "⌃⌥⇧⌘".indexOf(a) - "⌃⌥⇧⌘".indexOf(b)).join("") !== modifiers) fail(file, `combo "${combo}" does not list its modifiers in ⌃⌥⇧⌘ order`);
  if (KEY_GLYPHS[key]) return modifiers + KEY_GLYPHS[key];
  if (/^f\d{1,2}$/u.test(key)) return modifiers + key.toUpperCase();
  if ([...key].length !== 1) fail(file, `combo "${combo}" names a key the generator does not know: ${key}`);
  return modifiers + key.toUpperCase();
}

const native = (catalog, locale, key) =>
  catalog.native?.[key] ?? fail(SOURCES.catalog(locale), `no "native" string for the shortcut title or category "${key}"`);

export function shortcutsPartial(actions, catalog, locale) {
  const labels = LABELS[locale];
  const categories = [...new Set(actions.map((action) => action.category))];
  return `${categories
    .map((category) => {
      const rows = actions
        .filter((action) => action.category === category)
        .map((action) => {
          const title = native(catalog, locale, action.title).replace("%d", action.count ?? "%d");
          const keys = action.defaults.map((combo) => `<kbd>${cell(displayCombo(combo))}</kbd>`).join(labels.or);
          return [cell(title), keys || labels.none];
        });
      return `## ${cell(native(catalog, locale, category))} [#${anchor(category)}]\n\n${table([labels.action, labels.shortcut], rows)}\n`;
    })
    .join("\n")}`;
}

// MARK: Settings

const lookup = (catalog, locale, key) =>
  key.split(".").reduce((node, part) => node?.[part], catalog) ?? fail(SOURCES.catalog(locale), `no string "${key}"`);

/** A catalog string whose `{placeholders}` are Blume variables (`{version}` becomes `{{version}}`). */
function catalogText(catalog, locale, key) {
  const text = lookup(catalog, locale, key);
  if (typeof text !== "string") fail(SOURCES.catalog(locale), `"${key}" is not a string`);
  return cell(text).replace(/\\\{(\w+)\\\}/gu, (_, name) => {
    if (name !== "version") fail(SOURCES.catalog(locale), `"${key}" has a placeholder {${name}} the reference cannot fill`);
    return `{{${name}}}`;
  });
}

export function settingsPartial(model, catalog, locale) {
  const labels = LABELS[locale];
  const known = new Set(model.SETTINGS_SECTIONS.map((section) => section.id));
  for (const setting of model.SETTINGS) {
    if (!known.has(setting.section)) fail(SOURCES.settings, `setting "${setting.id}" sits in section "${setting.section}", which no navigation group lists`);
  }
  const anchors = new Set();
  const pin = (id) => {
    if (anchors.has(id)) fail(SOURCES.settings, `two headings would share the anchor #${id}`);
    anchors.add(id);
    return id;
  };
  return model.SETTINGS_SECTIONS.flatMap((section) => {
    const groups = model.sectionGroups(section.id);
    if (groups.length === 0) return [];
    const parts = groups.map(({ groupKey, settings }) => {
      const rows = settings.map((id) => {
        const toggle = model.SETTING_TOGGLES[id];
        return [
          catalogText(catalog, locale, `settings.items.${id}.title`),
          catalogText(catalog, locale, `settings.items.${id}.description`),
          toggle ? labels[toggle.fallback ? "on" : "off"] : "",
        ];
      });
      const heading = `### ${catalogText(catalog, locale, groupKey)} [#${pin(`${section.id}-${anchor(groupKey.split(".").pop())}`)}]`;
      return `${heading}\n\n${table([labels.setting, labels.description, labels.default], rows)}\n`;
    });
    return [`## ${catalogText(catalog, locale, section.labelKey)} [#${pin(section.id)}]\n`, ...parts];
  }).join("\n");
}

// MARK: MCP tools

/**
 * Reads the Swift literals of a tool list: strings (with `"""` blocks), arrays, dictionaries, `NSNull()`,
 * `tool(…)` and `prop(…)`. Anything else throws, naming the file and line.
 */
export class SwiftReader {
  constructor(source, file) {
    this.source = source;
    this.file = file;
    this.at = 0;
  }

  fail(message) {
    const line = this.source.slice(0, this.at).split("\n").length;
    fail(`${this.file}:${line}`, `${message} (at "${this.source.slice(this.at, this.at + 40).split("\n")[0]}")`);
  }

  /** Moves past whitespace and comments, then past a match of the sticky `pattern`, which it returns. */
  match(pattern) {
    const space = /(?:\s|\/\/[^\n]*)*/y;
    space.lastIndex = this.at;
    space.exec(this.source);
    pattern.lastIndex = this.at = space.lastIndex;
    const found = pattern.exec(this.source);
    if (found) this.at = pattern.lastIndex;
    return found;
  }

  take(token) {
    return this.match(new RegExp(token.replace(/[$()*+.?[\\\]^{|}]/gu, "\\$&"), "y")) !== null;
  }

  expect(token) {
    if (!this.take(token)) this.fail(`expected "${token}"`);
  }

  value() {
    let value;
    const block = this.match(/"""\n([\s\S]*?)\n([ \t]*)"""/y);
    const string = block ? null : this.match(/"((?:[^"\\\n]|\\.)*)"/y);
    if (block) {
      // Swift strips the closing delimiter's indentation from every line.
      const indent = block[2];
      const lines = block[1].split("\n").map((line) => {
        if (line.trim() && !line.startsWith(indent)) this.fail('a """ line is indented less than its closing delimiter');
        return line.slice(indent.length);
      });
      value = this.unescape(lines.join("\n"));
    } else if (string) value = this.unescape(string[1]);
    else if (this.take("[")) value = this.collection();
    else if (this.take("NSNull()")) value = null;
    else if (this.take("AgentTools.tool(") || this.take("tool(")) value = this.tool();
    else if (this.take("AgentTools.prop(") || this.take("prop(")) {
      const type = this.value();
      this.expect(",");
      value = { type, description: this.value() };
      this.expect(")");
    } else this.fail("unexpected expression in a tool definition");
    this.take("as [Any]");
    return value;
  }

  unescape(raw) {
    return raw.replace(/\\([\s\S])/gu, (_, char) => {
      if (char === "(") this.fail("string interpolation");
      if (char === "\n") return "";
      return { "\\": "\\", '"': '"', "'": "'", n: "\n", t: "\t", 0: "\0" }[char] ?? this.fail(`unknown escape \\${char}`);
    });
  }

  collection() {
    if (this.take(":]")) return {};
    const items = [];
    const entries = {};
    let dictionary = false;
    for (let first = true; !this.take("]"); first = false) {
      if (!first) {
        this.expect(",");
        if (this.take("]")) break;
      }
      const item = this.value();
      if (first) dictionary = this.take(":");
      else if (dictionary) this.expect(":");
      if (!dictionary) {
        items.push(item);
        continue;
      }
      if (typeof item !== "string") this.fail("dictionary key is not a string");
      if (Object.hasOwn(entries, item)) this.fail(`duplicate key "${item}"`);
      entries[item] = this.value();
    }
    return dictionary ? entries : items;
  }

  tool() {
    const name = this.value();
    this.expect(",");
    const description = this.value();
    this.expect(",");
    const properties = this.value();
    const required = this.take(",") ? (this.expect("required:"), this.value()) : [];
    this.expect(")");
    if (typeof name !== "string" || typeof description !== "string" || !Array.isArray(required) || !properties || typeof properties !== "object" || Array.isArray(properties)) {
      this.fail("a tool is tool(name, description, [parameters], required: [names])");
    }
    return { name, description, properties, required };
  }
}

const SCHEMA_KEYS = new Set(["type", "enum", "items", "description", "properties", "required"]);

function checkSchema(schema, where, file) {
  if (schema === null || typeof schema !== "object" || Array.isArray(schema)) fail(file, `${where} is neither prop(…) nor a schema dictionary`);
  for (const key of Object.keys(schema)) if (!SCHEMA_KEYS.has(key)) fail(file, `${where} has a schema key the reference does not show: ${key}`);
  const types = [schema.type].flat();
  if (!types.length || types.some((type) => typeof type !== "string")) fail(file, `${where} has no type, or one that is not a string or a list of strings`);
  if (schema.description !== undefined && typeof schema.description !== "string") fail(file, `${where} has a description that is not a string`);
  if (schema.enum !== undefined && (!Array.isArray(schema.enum) || schema.enum.some((value) => value !== null && typeof value !== "string"))) fail(file, `${where} has an enum that is not a list of strings`);
  if (schema.items !== undefined) checkSchema(schema.items, `${where}[]`, file);
  if (schema.properties !== undefined) {
    for (const [name, inner] of Object.entries(schema.properties)) checkSchema(inner, `${where}.${name}`, file);
    for (const name of schema.required ?? []) if (!Object.hasOwn(schema.properties, name)) fail(file, `${where} requires "${name}", which it does not define`);
  }
}

const COMPOSED = "tabAndPageDefinitions + AgentInteractionTools.definitions + AgentDevTools.definitions";

/** The tools a file defines in its `static let …: [[String: Any]] = [ … ]` lists, and its browser pickers. */
export function parseTools(source, file) {
  const tools = [];
  for (const match of source.matchAll(/static let \w+: \[\[String: Any\]\] = \[/gu)) {
    const reader = new SwiftReader(source, file);
    reader.at = match.index + match[0].length;
    const list = reader.collection();
    if (!endsAt(source, reader.at)) reader.fail("a tool list must end at its closing ], or the reference misses what is added or filtered after it");
    for (const tool of Array.isArray(list) ? list : [list]) {
      if (!tool?.name || !tool.properties) reader.fail("a tool list holds something other than tool(…)");
      for (const [name, schema] of Object.entries(tool.properties)) checkSchema(schema, `${tool.name}.${name}`, file);
      for (const name of tool.required) if (!Object.hasOwn(tool.properties, name)) fail(file, `${tool.name} requires "${name}", which it does not define`);
      tools.push({ ...tool, file });
    }
  }
  for (const match of source.matchAll(/static let (\w+): \[\[String: Any\]\] = (?!\[)(.*)/gu)) {
    if (match[2] !== COMPOSED || !endsAt(source, match.index + match[0].length)) {
      fail(file, `${match[1]} is not "${COMPOSED}": the reference reads only the literal tool lists, so anything else added to it would be missed`);
    }
  }
  if (tools.length === 0) fail(file, "no tool definitions found");
  const pickers = source.match(/static let browserPickers: Set = (\[[^\]]*\])/u);
  return { tools, pickers: pickers ? new SwiftReader(pickers[1], file).value() : [] };
}

/** Every line-leading `tool("` in the agent sources must be a tool the readers found, or a list or file is missed. */
export function checkToolCount(parsed, sources) {
  const found = parsed.reduce((count, file) => count + file.tools.length, 0);
  const declared = Object.values(sources).reduce((count, source) => count + (source.match(/^\s*(?:AgentTools\.)?tool\("/gmu)?.length ?? 0), 0);
  if (declared !== found) {
    fail("Lilo/Agent", `${declared} tool(…) definitions start a line but the generator read ${found} from ${SOURCES.tools.join(", ")}: a tool list it does not know needs adding to SOURCES.tools (and GROUPS) in docs-site/scripts/generate.mjs, as a \`static let …: [[String: Any]] = [ … ]\` literal`);
  }
}

const typeText = (schema) => {
  const types = [schema.type].flat().map((type) => `\`${type}\`${type === "array" && schema.items ? ` of ${typeText(schema.items)}` : ""}`);
  const values = schema.enum ? `: ${schema.enum.map((value) => `\`${value}\``).join(", ")}` : "";
  return types.join(" or ") + values;
};

function parameterRows(properties, required, prefix = "") {
  return Object.entries(properties).flatMap(([name, schema]) => {
    const path = `${prefix}${name}`;
    const nested = schema.items?.properties ? [schema.items, `${path}[].`] : schema.properties ? [schema, `${path}.`] : null;
    return [
      [cell(`\`${path}\``), cell(typeText(schema)), required.includes(name) ? "yes" : "no", cell(schema.description ?? "")],
      ...(nested ? parameterRows(nested[0].properties, nested[0].required ?? [], nested[1]) : []),
    ];
  });
}

const GROUPS = { "Lilo/Agent/AgentTools.swift": "Tabs and pages", "Lilo/Agent/AgentInteractionTools.swift": "Interaction", "Lilo/Agent/AgentDevTools.swift": "Developer tools" };

export function mcpPartial(parsed, summaries) {
  const tools = parsed.flatMap((file) => file.tools);
  const pickers = new Set(parsed.flatMap((file) => file.pickers));
  const names = new Set();
  for (const tool of tools) {
    if (names.has(tool.name)) fail(tool.file, `two tools are named "${tool.name}"`);
    names.add(tool.name);
  }
  for (const tool of tools) {
    if (typeof summaries[tool.name] !== "string" || !summaries[tool.name].trim()) fail(SOURCES.summaries, `no summary for the tool "${tool.name}" (${tool.file}): add one to ${SOURCES.summaries}`);
  }
  for (const name of Object.keys(summaries)) if (!names.has(name)) fail(SOURCES.summaries, `summary for "${name}", a tool no Swift file defines: rename or remove it in ${SOURCES.summaries}`);
  for (const name of pickers) if (!names.has(name)) fail(SOURCES.tools[1], `browserPickers names "${name}", which is not a tool`);
  const sections = parsed.map(({ tools: own }) => {
    const file = own[0].file;
    const body = own
      .filter((tool) => !pickers.has(tool.name))
      .map((tool) => {
        const rows = parameterRows(tool.properties, tool.required);
        const params = rows.length ? table(["Parameter", "Type", "Required", "Description"], rows) : "No parameters.";
        return `### \`${tool.name}\` [#${tool.name}]\n\n${cell(summaries[tool.name])}\n\n${params}\n`;
      });
    return `## ${GROUPS[file] ?? fail(file, "no group heading for this file")} [#${anchor(GROUPS[file])}]\n\n${body.join("\n")}`;
  });
  const closing = tools
    .filter((tool) => pickers.has(tool.name))
    .map((tool) => [cell(`\`${tool.name}\``), cell(Object.keys(tool.properties).map((name) => `\`${name}\``).join(", ")) || "none", cell(summaries[tool.name])]);
  const pickerSection = closing.length ? `## Browser selection [#browser-selection]\n\n${table(["Tool", "Parameters", "Summary"], closing)}\n` : "";
  return [...sections, pickerSection].filter(Boolean).join("\n");
}

// MARK: Compatibility

/** GitHub's anchor for a heading, which COMPATIBILITY.md's own links use. */
const githubSlug = (heading) => heading.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/gu, "-");

const FENCE = /(^```[^\n]*\n[\s\S]*?^```[^\n]*$)/mu;
const outsideFences = (text, edit) => text.split(FENCE).map((part, index) => (index % 2 ? part : edit(part))).join("");

/** The level-2 sections of COMPATIBILITY.md, each assigned to a page by its exact heading, as page bodies. */
export function compatibilityPartials(markdown, pages) {
  const file = SOURCES.compatibility;
  const sections = [];
  let fenced = false;
  for (const line of markdown.split("\n")) {
    if (line.startsWith("```")) fenced = !fenced;
    if (!fenced && line.startsWith("## ")) {
      if (sections.some((section) => section.heading === line.slice(3))) fail(file, `two "${line}" sections: the docs would publish only the first`);
      sections.push({ heading: line.slice(3), lines: [] });
    }
    sections.at(-1)?.lines.push(line);
  }
  const owner = new Map();
  const slices = Object.entries(pages).map(([route, headings]) => {
    const own = headings.map((heading) => sections.find((section) => section.heading === heading) ?? fail(file, `no "## ${heading}" heading`)).map((section) => section.lines.join("\n"));
    for (const section of own) {
      const prose = section.split(FENCE).filter((_, index) => index % 2 === 0).join("\n");
      for (const [, heading] of prose.matchAll(/^#{2,6} (.+)$/gmu)) {
        if (owner.has(githubSlug(heading))) fail(file, `two headings share the anchor #${githubSlug(heading)}`);
        owner.set(githubSlug(heading), route);
      }
    }
    return [route, own.map((section) => section.replace(/\n---\s*$/u, "").trim()).join("\n\n")];
  });
  const published = new Set(Object.values(pages).flat());
  for (const { heading } of sections) {
    if (!published.has(heading)) fail(file, `the section "## ${heading}" is on no docs page: add it to a page's list in compatibilityPartials' caller in docs-site/scripts/generate.mjs (${Object.keys(pages).join(" or ")})`);
  }
  return Object.fromEntries(
    slices.map(([route, text]) => [
      route,
      `${outsideFences(text, (prose) =>
        prose
          .replace(/^(#{2,6} .+)$/gmu, (_, heading) => `${heading} [#${githubSlug(heading.replace(/^#+ /u, ""))}]`)
          .replace(/\]\(([^)\s]+)\)/gu, (link, target) => {
            if (/^[a-z]+:/u.test(target)) return link;
            if (target.startsWith("#")) {
              const page = owner.get(target.slice(1)) ?? fail(file, `link to ${target}, a heading outside the published sections`);
              return page === route ? link : `](${page}${target})`;
            }
            return `](https://github.com/Alexays/Lilo/blob/main/${target})`;
          }),
      )
        .split(/(```[\s\S]*?```|`[^`]*`)/u)
        .map((part, index) => (index % 2 ? part : part.replace(/[{}<^~]/gu, "\\$&")))
        .join("")}\n`,
    ]),
  );
}

// MARK: Output

/** The settings model, which plain Node loads by stripping its types: anything else in it fails here. */
export async function loadSettings(path = `${repo}${SOURCES.settings}`) {
  try {
    return await import(path);
  } catch (error) {
    return fail(SOURCES.settings, `plain Node cannot load it (${error.message.split("\n")[0]}): keep it to type-only imports, no enum or other TypeScript-only syntax`);
  }
}

/** What a contributor who only touched app code reads when the generator fails. */
export const errorReport = (error) =>
  `docs-site/scripts/generate.mjs, which builds the docs reference tables from the app's sources, failed on ${error.message}\nFix the source it names as the message says (or the generator), then run make docs-check.`;

/** Partial path, relative to docs-site/, to its Markdown. */
export async function partials() {
  const catalogs = { en: JSON.parse(read(SOURCES.catalog("en"))), fr: JSON.parse(read(SOURCES.catalog("fr"))) };
  const actions = parseShortcuts(read(SOURCES.shortcuts));
  const model = await loadSettings();
  const tools = SOURCES.tools.map((file) => parseTools(read(file), file));
  const agent = readdirSync(`${repo}Lilo/Agent`).filter((name) => name.endsWith(".swift"));
  checkToolCount(tools, Object.fromEntries(agent.map((name) => [name, read(`Lilo/Agent/${name}`)])));
  const compatibility = compatibilityPartials(read(SOURCES.compatibility), {
    "/reference/extension-compatibility": ["Chrome extensions"],
    "/reference/web-compatibility": ["Web APIs", "Known Limitations (WebKit/macOS level - no fix possible in Lilo)"],
  });
  return {
    "content/reference/_generated/shortcuts.md": shortcutsPartial(actions, catalogs.en, "en"),
    "content/fr/reference/_generated/shortcuts.md": shortcutsPartial(actions, catalogs.fr, "fr"),
    "content/reference/_generated/settings.md": settingsPartial(model, catalogs.en, "en"),
    "content/fr/reference/_generated/settings.md": settingsPartial(model, catalogs.fr, "fr"),
    "content/reference/_generated/mcp-tools.md": mcpPartial(tools, JSON.parse(read(SOURCES.summaries))),
    "content/reference/_generated/extension-compatibility.md": compatibility["/reference/extension-compatibility"],
    "content/reference/_generated/web-compatibility.md": compatibility["/reference/web-compatibility"],
  };
}

function write(path, text) {
  const file = `${docs}${path}`;
  let current;
  try {
    current = readFileSync(file, "utf-8");
  } catch {
    current = undefined;
  }
  if (current !== text) {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, text);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    for (const [path, text] of Object.entries(await partials())) write(path, text);
  } catch (error) {
    console.error(errorReport(error));
    process.exit(1);
  }
}
