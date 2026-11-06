// Pure presentation logic for the extensions panel (list + detail).

import { parseHexColor, relativeLuminance } from "../../lib/sidebarTheme";

export type ExtensionRuntimeStatus = "loaded" | "degraded" | "failed";

interface ExtensionLike {
  id: string;
  name: string;
  description: string;
  version: string;
  hasPopup: boolean;
  hasBackground: boolean;
  hasContentScripts: boolean;
  runtimeStatus?: ExtensionRuntimeStatus;
  permissions?: string[];
  hostPermissions?: string[];
  siteAccess?: string[] | null;
}

export type ExtensionCapability = "popup" | "background" | "content";

/** Normalize the native `runtimeStatus` string; anything unknown is treated as healthy. */
export function coerceRuntimeStatus(value: unknown): ExtensionRuntimeStatus {
  return value === "degraded" || value === "failed" ? value : "loaded";
}

/** True when the extension's background failed and WebKit could not revive it. */
export function isExtensionDegraded(ext: ExtensionLike): boolean {
  return ext.runtimeStatus === "degraded";
}

export function resolveDisplayName(ext: ExtensionLike): string {
  return /^__MSG_.+__$/.test(ext.name) ? ext.description || ext.id : ext.name;
}

export function displayInitial(ext: ExtensionLike): string {
  const value = resolveDisplayName(ext).trim();
  return value ? value.charAt(0).toUpperCase() : "?";
}

const nameCollator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

/** The rows matching `query`, by display name so enabling or disabling one never moves it. */
export function filterExtensions<T extends ExtensionLike>(
  extensions: T[],
  query: string,
): T[] {
  const trimmed = query.trim().toLowerCase();
  const matches = trimmed
    ? extensions.filter(
        (ext) =>
          resolveDisplayName(ext).toLowerCase().includes(trimmed) ||
          ext.id.toLowerCase().includes(trimmed) ||
          ext.description.toLowerCase().includes(trimmed) ||
          ext.version.toLowerCase().includes(trimmed),
      )
    : extensions.slice();
  return matches.sort(
    (a, b) => nameCollator.compare(resolveDisplayName(a), resolveDisplayName(b)) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  );
}

export function extensionCapabilities(
  ext: ExtensionLike,
): ExtensionCapability[] {
  const capabilities: ExtensionCapability[] = [];
  if (ext.hasPopup) capabilities.push("popup");
  if (ext.hasBackground) capabilities.push("background");
  if (ext.hasContentScripts) capabilities.push("content");
  return capabilities;
}

export function permissionChips(ext: ExtensionLike): string[] {
  return [...(ext.permissions ?? []), ...(ext.hostPermissions ?? [])];
}

/**
 * A pasted URL keeps only its host and `www.` is dropped, so one entry covers the domain and its subdomains.
 * Returns "" for an unusable host, which disables the add button.
 */
export function normalizeSiteHost(value: string): string {
  let host = value.trim().toLowerCase();
  const scheme = host.indexOf("://");
  if (scheme >= 0) host = host.slice(scheme + 3);
  host = host.split(/[/?#]/)[0];
  if (host.startsWith("www.")) host = host.slice(4);
  if (!host.includes(".") || host.startsWith(".") || host.endsWith(".")) return "";
  return host;
}

// NSEvent.ModifierFlags bits, in the order macOS displays them.
const MODIFIER_GLYPHS: [number, string][] = [
  [1 << 18, "⌃"],
  [1 << 19, "⌥"],
  [1 << 17, "⇧"],
  [1 << 20, "⌘"],
];

export function formatShortcut(key: string, modifiers: number): string {
  const glyphs = MODIFIER_GLYPHS.filter(([flag]) => modifiers & flag).map(([, glyph]) => glyph);
  return `${glyphs.join("")}${key.toUpperCase()}`;
}

/**
 * The shortcut a keydown records, or null when it cannot be one: it needs a letter, digit or
 * punctuation key and a modifier besides Shift, so it never steals plain typing from pages.
 */
export function shortcutFromKeyEvent(event: {
  key: string;
  code: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
}): { key: string; modifiers: number } | null {
  // The code, not the key: Option turns letters into symbols.
  const physical = /^(?:Key|Digit)(\w)$/.exec(event.code)?.[1];
  const key = (physical ?? (event.key.length === 1 ? event.key : "")).toLowerCase();
  const modifiers =
    (event.ctrlKey ? 1 << 18 : 0) |
    (event.altKey ? 1 << 19 : 0) |
    (event.shiftKey ? 1 << 17 : 0) |
    (event.metaKey ? 1 << 20 : 0);
  if (!key || (modifiers & ~(1 << 17)) === 0) return null;
  return { key, modifiers };
}

/** The relative luminance where black and white contrast equally with a color. */
const LUMINANCE_MIDPOINT = 0.179;

/**
 * The badge text color: the extension's, else black or white, whichever contrasts more with the badge, as Chrome
 * picks it. Null for a background that is not a hex or rgb() color, which keeps the default.
 */
export function badgeTextColor(background = "", text = ""): string | null {
  if (text) return text;
  const value = background.trim();
  // As with rgba(), the alpha of #rgba and #rrggbbaa stays out of the luminance.
  const hex = /^#(?:([0-9a-f]{3})[0-9a-f]?|([0-9a-f]{6})(?:[0-9a-f]{2})?)$/i.exec(value);
  const rgb = /^rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)/i.exec(value);
  const color = hex ? parseHexColor(hex[1] ?? hex[2]) : rgb ? { r: Number(rgb[1]), g: Number(rgb[2]), b: Number(rgb[3]) } : null;
  if (!color) return null;
  return relativeLuminance(color) > LUMINANCE_MIDPOINT ? "#000" : "#fff";
}

// The address keeps this much of the bar's leading edge, room for the hover-revealed URL actions.
const ADDRESS_ROOM_PX = 96;
// The cluster sits 6px in from the bar's trailing edge and always holds the 20px menu button.
const CLUSTER_FIXED_PX = 6 + 20;
// A 20px pinned icon and the 4px gap after it.
const PIN_SLOT_PX = 24;

/** How many of `pins` pinned extensions an address bar `barWidth` wide shows; the rest, the last pinned, fold into the menu. */
export function fitPinnedCount(barWidth: number, pins: number): number {
  const slots = Math.floor((barWidth - ADDRESS_ROOM_PX - CLUSTER_FIXED_PX) / PIN_SLOT_PX);
  return Math.max(0, Math.min(pins, slots));
}
