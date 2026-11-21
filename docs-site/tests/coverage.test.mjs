// Cheap drift checks tying hand-written pages to the code they describe.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { displayCombo, parseShortcuts, read, SOURCES } from "../scripts/generate.mjs";

const content = fileURLToPath(new URL("../content", import.meta.url));
const page = (path) => readFileSync(join(content, path), "utf-8");

test("the import sources page names every browser Lilo scans", () => {
  const scanner = read("Lilo/Import/BrowserImportScanner.swift");
  // The (id, name, folder, …) tuples of the Chromium and Firefox families; Safari is scanned on its own.
  const browsers = [...scanner.matchAll(/\("\w+", "([^"]+)", "[^"]*", "[^"]*"(?:, "[^"]*")?\)/gu)].map((match) => match[1]).concat("Safari");
  assert.ok(browsers.length >= 12, `only ${browsers.length} browsers read from the scanner`);
  const text = page("reference/import-sources.mdx");
  for (const browser of browsers) assert.match(text, new RegExp(`^\\| ${browser} \\|`, "mu"), `${browser} has no row`);
});

test("the import sources page names every kind of data, as the import window does", () => {
  const kinds = read("Lilo/Import/ImportModels.swift").match(/enum ImportKind[^{]*\{\s*case ([\w, ]+)/u)[1].split(", ");
  const labels = JSON.parse(read(SOURCES.catalog("en"))).onboarding.import.kind;
  const text = page("reference/import-sources.mdx");
  assert.ok(kinds.length >= 5);
  for (const kind of kinds) {
    assert.ok(labels[kind], `no onboarding.import.kind.${kind} string`);
    assert.ok(text.includes(`**${labels[kind]}.**`), `"${labels[kind]}" (${kind}) is not described`);
  }
});

test("the macOS variable matches the deployment target", () => {
  const macos = readFileSync(new URL("../blume.config.ts", import.meta.url), "utf-8").match(/macos: "([^"]+)"/u)?.[1];
  const target = read("project.yml").match(/deploymentTarget:\s*\n\s*macOS: "([^"]+)"/u)?.[1];
  assert.ok(macos && target);
  assert.equal(macos, target.replace(/\.0$/u, ""));
});

const MODIFIERS = { cmd: "⌘", command: "⌘", ctrl: "⌃", control: "⌃", opt: "⌥", option: "⌥", alt: "⌥", shift: "⇧" };
const KEYS = { tab: "⇥", return: "↩", enter: "↩", esc: "⎋", escape: "⎋", delete: "⌫", backspace: "⌫", left: "←", right: "→", up: "↑", down: "↓" };

/** A shortcut as written in a page ("⌘T", "Cmd+T", "⌃Tab", "Shift-⌘S") in the menus' notation: "⌘T", "⌃⇥", "⇧⌘S". */
function notation(written) {
  const parts = written.replaceAll("\\", "").trim().split(/(?<=\S)[+-](?=\S)|\s+/u);
  let modifiers = "";
  let key = parts.pop() ?? "";
  for (const part of parts) modifiers += MODIFIERS[part.toLowerCase()] ?? part;
  const glyphs = key.match(/^[⌃⌥⇧⌘]+/u)?.[0] ?? "";
  modifiers += glyphs;
  key = key.slice(glyphs.length);
  key = KEYS[key.toLowerCase()] ?? (key.length === 1 ? key.toUpperCase() : key);
  return [...modifiers].sort((a, b) => "⌃⌥⇧⌘".indexOf(a) - "⌃⌥⇧⌘".indexOf(b)).join("") + key;
}

test("every key written in a page is a shortcut of Lilo's or a known contextual key", () => {
  const swift = read(SOURCES.shortcuts);
  // Default keys, and those of the presets a page may describe.
  const presets = swift.slice(swift.indexOf("static let presets"), swift.indexOf("static let actionsById"));
  const combos = [...parseShortcuts(swift).flatMap((action) => action.defaults), ...[...presets.matchAll(/"([⌃⌥⇧⌘][^"]*)"/gu)].map((match) => match[1])];
  const known = new Set(combos.map((combo) => displayCombo(combo)));
  const contextual = JSON.parse(readFileSync(new URL("contextual-keys.json", import.meta.url), "utf-8"));
  const allowed = new Set([...contextual, ...contextual.map(notation)]);
  const pages = readdirSync(content, { recursive: true }).filter((entry) => /\.mdx?$/u.test(entry) && !entry.startsWith("fr/") && !entry.includes("_generated"));
  for (const entry of pages) {
    for (const [run] of page(entry).matchAll(/(?:<kbd>[^<]*<\/kbd>\+?)+/gu)) {
      const caps = [...run.matchAll(/<kbd>([^<]*)<\/kbd>/gu)].map((match) => match[1]);
      // Keycaps written together (<kbd>⌘</kbd><kbd>T</kbd>, <kbd>Cmd</kbd>+<kbd>T</kbd>) spell one shortcut.
      const shortcuts = caps.length > 1 ? [caps.join("+")] : caps;
      for (const written of shortcuts) {
        const keys = notation(written);
        assert.ok(known.has(keys) || allowed.has(written) || allowed.has(keys), `${entry}: <kbd>${written}</kbd> (${keys}) is no shortcut in ${SOURCES.shortcuts}; if it is a contextual key, ask for it in tests/contextual-keys.json`);
      }
    }
  }
});

test("the shortcut notation reader accepts the common spellings", () => {
  for (const written of ["⌘T", "Cmd+T", "cmd-t", "Command T", "⌘+T", "⌘ T"]) assert.equal(notation(written), "⌘T", written);
  assert.equal(notation("Shift+⌘S"), "⇧⌘S");
  assert.equal(notation("⌘⇧S"), "⇧⌘S");
  assert.equal(notation("⌃Tab"), "⌃⇥");
  assert.equal(notation("Ctrl+Shift+-"), "⌃⇧-");
  assert.equal(notation("⌃⌘Left"), "⌃⌘←");
});
