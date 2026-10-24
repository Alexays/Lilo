import { on } from "../lib/bridge";
import { setSearchEngines } from "../lib/inputParser";
import { parseSearchEngines } from "../lib/searchEngineModel";

// Mirrors the persisted `searchEngines` setting into the omnibox engine registry (`inputParser`).
export function initSearchEngineStore(): void {
  on("settingsLoaded", (data) => {
    setSearchEngines(parseSearchEngines(data.settings?.searchEngines));
  });
}
