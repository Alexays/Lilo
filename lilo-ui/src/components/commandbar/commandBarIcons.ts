// Pure icon resolution for command-bar results: favicon when the UI already has one (open tabs),
// a line icon for actions and terminals, a Space's own glyph, a letter monogram otherwise.

import { hostOf } from "../../lib/url";

interface TabFaviconLookup {
  byTabId: Map<string, string>;
  byHost: Map<string, string>;
}

type ResultIconSpec =
  | { type: "favicon"; src: string; fallback: string }
  | { type: "line"; path: string }
  | { type: "glyph"; glyph: string }
  | { type: "letter"; letter: string };

// Path data on a 16x16 grid, drawn centered on (8, 8) and stroked like the address bar's icons.
export const LINE_ICONS: Record<string, string> = {
  plus: "M8 3.5v9M3.5 8h9",
  closeTab: "M2.5 4h11v8h-11zM6.5 6.5l3 3M9.5 6.5l-3 3",
  gear: "M12.85 6.79L14.54 7.08L14.54 8.92L12.85 9.21L12.29 10.58L13.27 11.97L11.97 13.27L10.58 12.29L9.21 12.85L8.92 14.54L7.08 14.54L6.79 12.85L5.42 12.29L4.03 13.27L2.73 11.97L3.71 10.58L3.15 9.21L1.46 8.92L1.46 7.08L3.15 6.79L3.71 5.42L2.73 4.03L4.03 2.73L5.42 3.71L6.79 3.15L7.08 1.46L8.92 1.46L9.21 3.15L10.58 3.71L11.97 2.73L13.27 4.03L12.29 5.42ZM8 5.8a2.2 2.2 0 1 0 0 4.4a2.2 2.2 0 1 0 0-4.4z",
  flag: "M4 14V2M4 2.8h8l-2 2.85 2 2.85H4",
  pulse: "M1.5 8.5h3l1.7-4.5 3.3 8 1.7-3.5h3.3",
  sparkle: "M8 2l1.5 4.5L14 8l-4.5 1.5L8 14l-1.5-4.5L2 8l4.5-1.5z",
  spaceAdd: "M2.5 2.5h4.5v4.5H2.5zM9 2.5h4.5v4.5H9zM2.5 9h4.5v4.5H2.5zM11.25 9v4.5M9 11.25h4.5",
  eyeOff: "M1.5 8s2.4-4.25 6.5-4.25S14.5 8 14.5 8s-2.4 4.25-6.5 4.25S1.5 8 1.5 8zM8 6.25a1.75 1.75 0 1 0 0 3.5a1.75 1.75 0 1 0 0-3.5zM2.5 13.5l11-11",
  sidebar: "M2 3h12v10H2zM6 3v10",
  reload: "M12.75 8a4.75 4.75 0 1 1-1.4-3.36M12.5 2.25v2.75H9.75",
  back: "M10 3L5 8l5 5",
  forward: "M6 3l5 5-5 5",
  stop: "M4 4l8 8M12 4l-8 8",
  zoomIn: "M7 2.5a4.5 4.5 0 1 0 0 9a4.5 4.5 0 1 0 0-9zM10.25 10.25l3.75 3.75M7 5v4M5 7h4",
  zoomOut: "M7 2.5a4.5 4.5 0 1 0 0 9a4.5 4.5 0 1 0 0-9zM10.25 10.25l3.75 3.75M5 7h4",
  zoomReset: "M7 2.5a4.5 4.5 0 1 0 0 9a4.5 4.5 0 1 0 0-9zM10.25 10.25l3.75 3.75M5 6h4M5 8h4",
  camera: "M2 5.25A1.25 1.25 0 0 1 3.25 4h1.9l1.1-1.5h3.5l1.1 1.5h1.9A1.25 1.25 0 0 1 14 5.25v6.5A1.25 1.25 0 0 1 12.75 13h-9.5A1.25 1.25 0 0 1 2 11.75zM8 6a2.25 2.25 0 1 0 0 4.5a2.25 2.25 0 1 0 0-4.5z",
  key: "M5.75 3.5a3 3 0 1 0 0 6a3 3 0 1 0 0-6zM8.35 8L14 13.65M11.5 11.15l1.5-1.5",
  undo: "M3 6.5h6.5a3.25 3.25 0 0 1 0 6.5H7M5.75 3.75L3 6.5l2.75 2.75",
  trash: "M2.5 4.5h11M6.25 4.5V2.75h3.5V4.5M4 4.5l.75 9h6.5l.75-9",
  mute: "M2 6h2.75L8 3v10L4.75 10H2zM10.5 6l3.5 4M14 6l-3.5 4",
  star: "M8 2l1.85 3.75 4.15.6-3 2.92.7 4.13L8 11.45 4.3 13.4l.7-4.13-3-2.92 4.15-.6z",
  globe: "M8 2a6 6 0 1 0 0 12a6 6 0 1 0 0-12zM2 8h12M8 2c-2 1.8-2 10.2 0 12M8 2c2 1.8 2 10.2 0 12",
  code: "M5.5 4.5L2 8l3.5 3.5M10.5 4.5L14 8l-3.5 3.5M9.25 2.5l-2.5 11",
  download: "M8 2v8M4.75 6.75L8 10l3.25-3.25M2.5 13.5h11",
  terminal: "M2 3h12v10H2zM4.75 6.25L6.75 8l-2 1.75M8.5 10h2.75",
  terminalNext: "M2 3h12v10H2zM4.75 6.25L6.75 8l-2 1.75M9 6.5l2 1.5-2 1.5",
  prompt: "M3.5 4.5L7 8l-3.5 3.5M8.5 11.5h4",
  history: "M8 2.5a5.5 5.5 0 1 0 0 11a5.5 5.5 0 1 0 0-11zM8 5v3.25l2.25 1.5",
  diff: "M8 2.5v6M5 5.5h6M5 12.5h6",
  split: "M2 3h12v10H2zM8 3v10",
  unsplit: "M2 3h12v10H2z",
  find: "M7 2.5a4.5 4.5 0 1 0 0 9a4.5 4.5 0 1 0 0-9zM10.25 10.25l3.75 3.75",
  reader: "M3 2.5h10v11H3zM5.5 5.5h5M5.5 8h5M5.5 10.5h3",
  link: "M6.75 9.25l2.5-2.5M7.5 4.75l1-1a2.47 2.47 0 0 1 3.5 3.5l-1 1M8.5 11.25l-1 1a2.47 2.47 0 0 1-3.5-3.5l1-1",
  pin: "M6 2.5h4M6.75 2.5v4L4.5 9h7L9.25 6.5v-4M8 9v4.5",
  duplicate: "M5.5 5.5h8v8h-8zM2.5 10.5v-8h8",
  crop: "M4.5 1.5v10h10M1.5 4.5h10v10",
};

interface ResultLike {
  kind: string;
  icon?: string;
  url?: string;
  payload: Record<string, unknown>;
}

interface TabLike {
  id: string;
  url?: string;
  faviconDataURL?: string;
}

const GLYPH_KINDS = new Set(["action", "terminal", "terminalTab", "closedTerminal", "clearArchive", "showAllHistory", "space", "moveToSpace"]);

// Tab snapshots are replaced, never mutated, on every patch: keying the parsed host by
// identity spares a URL parse per tab on each rebuild.
const hostByTab = new WeakMap<TabLike, string | null>();

export function buildTabFaviconLookup(tabs: TabLike[]): TabFaviconLookup {
  const byTabId = new Map<string, string>();
  const byHost = new Map<string, string>();
  for (const tab of tabs) {
    const src = tab.faviconDataURL;
    if (!src) continue;
    byTabId.set(tab.id, src);
    let host = hostByTab.get(tab);
    if (host === undefined) {
      host = hostOf(tab.url);
      hostByTab.set(tab, host);
    }
    if (host && !byHost.has(host)) byHost.set(host, src);
  }
  return { byTabId, byHost };
}

function monogram(host: string | null): string {
  return host ? host.charAt(0).toUpperCase() : "?";
}

export function resolveResultIcon(
  result: ResultLike,
  lookup: TabFaviconLookup,
): ResultIconSpec {
  if (GLYPH_KINDS.has(result.kind)) {
    const path = result.icon ? LINE_ICONS[result.icon] : undefined;
    return path ? { type: "line", path } : { type: "glyph", glyph: result.icon || "•" };
  }

  const host = hostOf(result.url);
  const fallback = monogram(host);

  const tabId = result.payload["tabId"];
  if (typeof tabId === "string") {
    const src = lookup.byTabId.get(tabId);
    if (src) return { type: "favicon", src, fallback };
  }

  if (host) {
    const src = lookup.byHost.get(host);
    if (src) return { type: "favicon", src, fallback };
  }

  return { type: "letter", letter: fallback };
}
