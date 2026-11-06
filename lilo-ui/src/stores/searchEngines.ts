import { on } from "../lib/bridge";
import { setSearchEngines } from "../lib/inputParser";
import { parseSearchEngines } from "../lib/searchEngineModel";

// Mirrors the persisted `searchEngines` setting into the omnibox engine registry (`inputParser`).
export function initSearchEngineStore(): void {
  // Every setting change republishes all settings: an unchanged value keeps the parsed engines.
  let setting: string | undefined;
  on("settingsLoaded", (data) => {
    if (data.settings?.searchEngines === setting) return;
    setting = data.settings?.searchEngines;
    setSearchEngines(parseSearchEngines(setting));
  });
}
