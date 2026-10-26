import type { BridgeEventPayloadMap } from "../../../lilo-ui/src/lib/bridge/protocol";

export interface DemoAssets {
  appIcons: BridgeEventPayloadMap["appIconsLoaded"]["icons"];
  images: {
    bitwarden: string;
    board: string;
    browser: string;
    codex: string;
    darkReader: string;
    github: string;
    lilo: string;
    music: string;
    notes: string;
    travel: string;
  };
}

const pageIcons = new Map<string, keyof DemoAssets["images"]>([
  ["github.com", "github"],
  ["getlilo.app", "lilo"],
  ["mcp.example.com", "codex"],
  ["notes.example.com", "notes"],
  ["project.example.com", "browser"],
  ["radio.example.com", "music"],
  ["slowtravel.example.com", "travel"],
  ["studio.example.com", "board"],
  ["tracker.example.com", "board"],
]);

export const sampleFavicon = (url: string, assets?: DemoAssets) => {
  if (!url || !assets) {
    return "";
  }

  return assets.images[pageIcons.get(new URL(url).hostname) ?? "browser"];
};
