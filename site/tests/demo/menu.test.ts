import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  defaultMenuShortcutKeys,
  demoMenus,
  menuActionEnabled,
  menuLabelKeys,
  parseMenuMessage,
} from "../../src/demo/menu.ts";
import type {
  DemoMenuEntry,
  DemoMenuItem,
  DemoMenuState,
} from "../../src/demo/menu.ts";

const items = (entries: DemoMenuEntry[]): DemoMenuItem[] =>
  entries.flatMap((entry) =>
    "separator" in entry ? [] : [entry, ...items(entry.children ?? [])]
  );

test("the demo keeps every native application menu in its native order and groups", () => {
  const [source] = readFileSync(
    new URL("../../../Lilo/App/MainMenu.swift", import.meta.url),
    "utf-8"
  ).split("NSApp.mainMenu = mainMenu");

  const paths = new Map([["mainMenu", ""]]);
  const expected = new Map<string, string[]>([["", []]]);

  for (const line of source.split("\n")) {
    const submenu =
      /submenu\("(?<label>[^"]+)"(?:\.localized)?, in: (?<parent>\w+)/u.exec(
        line
      );

    if (submenu) {
      assert.ok(submenu.groups);
      const { label, parent } = submenu.groups;
      const parentPath = paths.get(parent);
      assert.ok(parentPath !== undefined);
      const parentItems = expected.get(parentPath);
      assert.ok(parentItems);
      parentItems.push(label);
      const path = `${parentPath}/${label}`;

      const variable = /let (?<variable>\w+) = submenu/u.exec(line)?.groups
        ?.variable;

      if (variable) {
        paths.set(variable, path);
        expected.set(path, []);
      }
    }

    const row = /(?<variable>\w+)\.add\("(?<label>[^"]+)"/u.exec(line);

    const separator =
      /(?<variable>\w+)\.addItem\((?:\.separator\(\)|separator)\)/u.exec(line);

    const variable = row?.groups?.variable ?? separator?.groups?.variable;

    if (variable) {
      const path = paths.get(variable);
      assert.ok(path !== undefined);
      const menuItems = expected.get(path);
      assert.ok(menuItems);
      menuItems.push(row?.groups?.label ?? "|");
    }
  }

  const actual = new Map<string, string[]>();

  const collect = (entries: DemoMenuEntry[], path = "") => {
    const labels: string[] = [];

    for (const entry of entries) {
      if ("separator" in entry) {
        labels.push("|");
      } else if (entry.dynamic !== "spaces") {
        labels.push(entry.label);

        if (entry.children) {
          collect(entry.children, `${path}/${entry.label}`);
        }
      }
    }

    actual.set(path, labels);
  };

  collect(demoMenus);

  for (const [path, labels] of expected) {
    if (labels.length) {
      assert.deepEqual(actual.get(path), labels, path || "Menu bar");
    }
  }
});

test("menu labels use the native English and French translations", () => {
  for (const locale of ["en", "fr"]) {
    // SAFETY: both catalogs are repository-owned native localization sources.
    const { native } = JSON.parse(
      readFileSync(
        new URL(
          `../../../lilo-ui/src/lib/i18n/locales/${locale}.json`,
          import.meta.url
        ),
        "utf-8"
      )
    ) as { native: Record<string, string> };

    for (const item of items(demoMenus)) {
      const key = /^Tab \d$/u.test(item.label) ? "Tab %d" : item.label;

      if (key !== "Lilo") {
        assert.ok(native[key], `${locale}: ${key}`);
      }
    }

    for (const key of menuLabelKeys.filter((label) => label !== "Lilo")) {
      assert.ok(native[key], `${locale}: ${key}`);
    }
  }
});

test("menu shortcut hints use Lilo defaults rather than the Arc preset", () => {
  const [source] = readFileSync(
    new URL("../../../Lilo/App/KeyboardShortcuts.swift", import.meta.url),
    "utf-8"
  ).split("static let presets:");

  const native = Object.fromEntries(
    [
      ...source.matchAll(/Action\("(?<id>[^"]+)",[^\n]+?\["(?<combo>[^"]+)"/gu),
    ].map((match) => {
      assert.ok(match.groups);
      const { id, combo } = match.groups;

      return [
        id,
        combo
          .replace(/right$/u, "→")
          .replace(/left$/u, "←")
          .replace(/delete$/u, "⌫")
          .toUpperCase(),
      ];
    })
  );

  for (const [id, keys] of Object.entries(defaultMenuShortcutKeys)) {
    const ordinal = /^tab\.select(?<ordinal>\d)$/u.exec(id)?.groups?.ordinal;
    assert.equal(keys, ordinal ? `⌘${ordinal}` : native[id], id);
  }

  assert.equal(defaultMenuShortcutKeys["sidebar.toggle"], "⇧⌘S");
  assert.equal(defaultMenuShortcutKeys["page.save"], "⌘S");
});

test("Mac system actions stay unavailable and website controls stay outside native menus", () => {
  const menuItems = items(demoMenus);

  for (const item of menuItems.filter((entry) => entry.macOnly)) {
    assert.equal(item.action, undefined, item.label);
  }

  assert.equal(
    menuItems.some((item) => item.action === "reset"),
    false
  );
  assert.equal(
    menuItems.some((item) => item.action === "explore"),
    false
  );
  assert.equal(
    menuItems.find((item) => item.action === "closeOtherTabs")?.alternate,
    "option"
  );
  assert.equal(
    menuItems.find((item) => item.action === "reloadFromOrigin")?.alternate,
    "shift"
  );
});

const state: DemoMenuState = {
  activeTabKind: "web",
  canGoBack: false,
  canGoForward: false,
  canReopenTab: false,
  hasActiveTab: true,
  hasSplit: false,
  isBookmarked: false,
  isMuted: false,
  isPinned: false,
  sidebarVisible: true,
  spaces: [{ id: "personal", title: "Personal" }],
  supportedActions: items(demoMenus).flatMap((item) =>
    item.action ? [item.action] : []
  ),
  tabs: [{ id: "notes", title: "Notes" }],
  type: "lilo-demo:menu-state",
};

test("menu messages reject malformed state and language payloads", () => {
  assert.deepEqual(parseMenuMessage({ data: state }), state);

  const labels = {
    labels: { File: "Fichier", "Tab %d": "Onglet %d" },
    locale: "fr",
    type: "lilo-demo:menu-labels",
  };

  assert.deepEqual(parseMenuMessage({ data: labels }), labels);
  assert.equal(
    parseMenuMessage({ data: { type: "lilo-demo:menu-state" } }),
    null
  );
  assert.equal(
    parseMenuMessage({
      data: { labels: { File: 7 }, type: "lilo-demo:menu-labels" },
    }),
    null
  );
  assert.equal(parseMenuMessage({ data: "lilo-demo:ready" }), null);
});

test("menu availability follows navigation, selection, split and sidebar state", () => {
  for (const action of [
    "back",
    "forward",
    "reopenTab",
    "openAsTab",
    "findNext",
    "findPrevious",
    "nextTab",
    "previousTab",
    "closeOtherTabs",
    "nextSpace",
    "previousSpace",
    "separateSplit",
    "selectTab2",
  ]) {
    assert.equal(menuActionEnabled(action, state), false, action);
  }

  for (const action of [
    "sidebar",
    "closeTab",
    "split",
    "selectTab1",
    "selectTab9",
  ]) {
    assert.equal(menuActionEnabled(action, state), true, action);
  }

  assert.equal(menuActionEnabled("back", { ...state, canGoBack: true }), true);
  assert.equal(
    menuActionEnabled("separateSplit", { ...state, hasSplit: true }),
    true
  );
  assert.equal(
    menuActionEnabled("split", { ...state, canSplit: false }),
    false
  );
  assert.equal(
    menuActionEnabled("sidebar", { ...state, sidebarLocked: true }),
    false
  );
  assert.equal(
    menuActionEnabled("pin", { ...state, hasActiveTab: false }),
    false
  );
  assert.equal(
    menuActionEnabled("reload", { ...state, activeTabKind: "terminal" }),
    false
  );
  assert.equal(
    menuActionEnabled("newTerminal", { ...state, terminalEnabled: false }),
    false
  );
  assert.equal(
    menuActionEnabled("settings", { ...state, supportedActions: [] }),
    false
  );
  assert.equal(
    menuActionEnabled("copyURL", { ...state, hasPageURL: false }),
    false
  );
  assert.equal(
    menuActionEnabled("duplicate", { ...state, hasPageURL: false }),
    false
  );
  assert.equal(menuActionEnabled("undo", { ...state, editActions: {} }), false);
  assert.equal(
    menuActionEnabled("copy", { ...state, editActions: { copy: true } }),
    true
  );
});
