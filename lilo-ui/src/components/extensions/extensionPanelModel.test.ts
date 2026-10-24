import assert from "node:assert/strict";
import test from "node:test";

import {
  badgeTextColor,
  coerceRuntimeStatus,
  displayInitial,
  extensionCapabilities,
  filterExtensions,
  formatShortcut,
  isExtensionDegraded,
  normalizeSiteHost,
  permissionChips,
  resolveDisplayName,
  shortcutFromKeyEvent,
} from "./extensionPanelModel";

const base = {
  id: "abc123",
  name: "Wappalyzer",
  description: "Identify web technologies",
  version: "6.12.2",
  hasPopup: true,
  hasBackground: false,
  hasContentScripts: true,
  permissions: ["storage", "tabs"],
  hostPermissions: ["https://*/*"],
};

test("resolves display name, falling back for __MSG_*__ placeholders", () => {
  assert.equal(resolveDisplayName(base), "Wappalyzer");
  assert.equal(
    resolveDisplayName({ ...base, name: "__MSG_appName__" }),
    "Identify web technologies",
  );
  assert.equal(
    resolveDisplayName({ ...base, name: "__MSG_appName__", description: "" }),
    "abc123",
  );
});

test("derives the avatar initial", () => {
  assert.equal(displayInitial(base), "W");
  assert.equal(displayInitial({ ...base, name: " dashlane" }), "D");
  assert.equal(
    displayInitial({ ...base, name: "__MSG_x__", description: "", id: "" }),
    "?",
  );
});

test("filters on name, id, description and version, case-insensitively", () => {
  const other = {
    ...base,
    id: "xyz789",
    name: "Dashlane",
    description: "Password manager",
    version: "6.2620.1",
  };
  const all = [base, other];

  assert.deepEqual(filterExtensions(all, ""), all);
  assert.deepEqual(filterExtensions(all, "  "), all);
  assert.deepEqual(filterExtensions(all, "wappa"), [base]);
  assert.deepEqual(filterExtensions(all, "XYZ"), [other]);
  assert.deepEqual(filterExtensions(all, "password"), [other]);
  assert.deepEqual(filterExtensions(all, "2620"), [other]);
  assert.deepEqual(filterExtensions(all, "nothing"), []);
});

test("filter matches the resolved display name for __MSG_*__ extensions", () => {
  const localized = {
    ...base,
    id: "loc1",
    name: "__MSG_appName__",
    description: "Traducteur",
  };
  assert.deepEqual(filterExtensions([localized], "traduc"), [localized]);
});

test("lists capabilities in display order", () => {
  assert.deepEqual(extensionCapabilities(base), ["popup", "content"]);
  assert.deepEqual(
    extensionCapabilities({ ...base, hasBackground: true }),
    ["popup", "background", "content"],
  );
  assert.deepEqual(
    extensionCapabilities({
      ...base,
      hasPopup: false,
      hasContentScripts: false,
    }),
    [],
  );
});

test("maps the native runtimeStatus string, defaulting unknown values to loaded", () => {
  // The store's parseExtension threads runtimeStatus through this coercion.
  assert.equal(coerceRuntimeStatus("degraded"), "degraded");
  assert.equal(coerceRuntimeStatus("failed"), "failed");
  assert.equal(coerceRuntimeStatus("loaded"), "loaded");
  assert.equal(coerceRuntimeStatus(undefined), "loaded");
  assert.equal(coerceRuntimeStatus("something-else"), "loaded");
});

test("flags degraded extensions for the panel indicator", () => {
  assert.equal(isExtensionDegraded({ ...base, runtimeStatus: "degraded" }), true);
  assert.equal(isExtensionDegraded({ ...base, runtimeStatus: "loaded" }), false);
  assert.equal(isExtensionDegraded(base), false);
});

test("merges manifest and host permissions for the detail chips", () => {
  assert.deepEqual(permissionChips(base), ["storage", "tabs", "https://*/*"]);
  assert.deepEqual(
    permissionChips({ ...base, permissions: undefined, hostPermissions: undefined }),
    [],
  );
});

test("normalizes a typed site into the host the native side stores", () => {
  assert.equal(normalizeSiteHost("  Example.ORG  "), "example.org");
  assert.equal(normalizeSiteHost("https://www.example.org/shop/cart?x=1"), "example.org");
  assert.equal(normalizeSiteHost("sub.example.com"), "sub.example.com");
});

test("rejects anything that is not a usable host", () => {
  assert.equal(normalizeSiteHost("localhost"), "");
  assert.equal(normalizeSiteHost(".com"), "");
  assert.equal(normalizeSiteHost("example."), "");
  assert.equal(normalizeSiteHost("   "), "");
});

const COMMAND = 1 << 20;
const SHIFT = 1 << 17;
const OPTION = 1 << 19;

test("formats a command shortcut in macOS modifier order", () => {
  assert.equal(formatShortcut("y", COMMAND | SHIFT), "⇧⌘Y");
  assert.equal(formatShortcut("k", COMMAND | OPTION), "⌥⌘K");
});

test("records a shortcut only with a modifier besides Shift", () => {
  const keys = { metaKey: false, ctrlKey: false, altKey: false, shiftKey: false };
  assert.deepEqual(
    shortcutFromKeyEvent({ ...keys, key: "˚", code: "KeyK", metaKey: true, altKey: true }),
    { key: "k", modifiers: COMMAND | OPTION },
    "Option-typed symbols record the physical key",
  );
  assert.deepEqual(shortcutFromKeyEvent({ ...keys, key: ",", code: "Comma", metaKey: true }), {
    key: ",",
    modifiers: COMMAND,
  });
  assert.equal(shortcutFromKeyEvent({ ...keys, key: "Y", code: "KeyY", shiftKey: true }), null);
  assert.equal(shortcutFromKeyEvent({ ...keys, key: "Meta", code: "MetaLeft", metaKey: true }), null);
});

test("a badge without a text color gets black or white, whichever contrasts more", () => {
  assert.equal(badgeTextColor("#FFFFFF", ""), "#000");
  assert.equal(badgeTextColor("#555", ""), "#fff");
  assert.equal(badgeTextColor("#eb0a00", ""), "#fff");
  assert.equal(badgeTextColor("rgba(255, 214, 0, 255)", ""), "#000");
  assert.equal(badgeTextColor("#eb0a00", "#ffff00"), "#ffff00");
  assert.equal(badgeTextColor("red", ""), null);
});
