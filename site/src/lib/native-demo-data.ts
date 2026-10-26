import type { BridgeTerminalTheme } from "../../../lilo-ui/src/lib/bridge/protocol";
import en from "../../../lilo-ui/src/lib/i18n/locales/en.json?raw";
import fr from "../../../lilo-ui/src/lib/i18n/locales/fr.json?raw";
import shortcuts from "../../../Lilo/App/KeyboardShortcuts.swift?raw";
import terminal from "../../../Lilo/Terminal/TerminalTheme.swift?raw";
import type { NativeCatalogs } from "../demo/native-copy";
import type { NativeShortcutAction } from "../demo/settings-state";

export interface NativeDemoData {
  copy: NativeCatalogs;
  shortcuts: NativeShortcutAction[];
  terminalThemes: BridgeTerminalTheme[];
}

const actions: NativeShortcutAction[] = [];

const literalAction =
  /Action\("(?<id>[^"\\]+)", "(?<title>[^"\\]+)", "(?<category>[^"\\]+)"(?:, \[(?<defaults>(?:\s*"[^"\\]*"\s*,?)*)\])?\)/gu;

for (const match of shortcuts.matchAll(literalAction)) {
  const [, id, title, category, defaults = ""] = match;
  actions.push({
    category,
    defaults: [...defaults.matchAll(/"(?<key>[^"\\]*)"/gu)].map(
      (key) => key[1]
    ),
    id,
    title,
  });

  const kind = new Map([
    ["space.previous", "space"],
    ["tab.recentPrevious", "tab"],
  ]).get(id);

  if (kind) {
    for (let ordinal = 1; ordinal <= 9; ordinal += 1) {
      let numberedTitle = "Tab %d";

      if (kind === "space") {
        numberedTitle = "Space %d";
      } else if (ordinal === 9) {
        numberedTitle = "Last Tab";
      }

      actions.push({
        args: [ordinal],
        category: kind === "space" ? "Spaces" : "Tab",
        defaults: [`${kind === "space" ? "⌃" : "⌘"}${ordinal}`],
        id: `${kind}.select${ordinal}`,
        title: numberedTitle,
      });
    }
  }
}

const colors = (source: string) =>
  [...source.matchAll(/0x(?<color>[\dA-Fa-f]{6})/gu)].map(
    (color) => `#${color[1].toLowerCase()}`
  );

const solarized = colors(
  terminal.match(
    /private static let solarized:[\s\S]*?= \[(?<palette>[\s\S]*?)\]/u
  )?.[1] ?? ""
);

const themes: BridgeTerminalTheme[] = [];

const preset =
  /preset\("(?<id>[^"]+)", "(?<name>[^"]+)", (?<background>0x[\dA-Fa-f]{6}), (?<foreground>0x[\dA-Fa-f]{6}), 0x[\dA-Fa-f]{6}, 0x[\dA-Fa-f]{6}, (?<palette>\[[\s\S]*?\]|solarized)\)/gu;

for (const [, id, name, background, foreground, palette] of terminal.matchAll(
  preset
)) {
  themes.push({
    background: colors(background)[0],
    foreground: colors(foreground)[0],
    id,
    name,
    palette: palette === "solarized" ? solarized : colors(palette),
  });
}

// SAFETY: both catalogs are trusted repository JSON; only their native namespace is shipped.
const copy = {
  en: JSON.parse(en).native,
  fr: JSON.parse(fr).native,
} as NativeCatalogs;

export const nativeDemoData: NativeDemoData = {
  copy,
  shortcuts: actions,
  terminalThemes: themes,
};
