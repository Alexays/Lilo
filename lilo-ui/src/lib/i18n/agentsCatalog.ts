import deferredCatalog from "./locales/en.json?raw";
import { catalogs } from "./translate";

// Agents' English copy is left out of the chrome's first frame: every agent surface imports this
// module, so it loads with the first one shown.
catalogs.en = { ...catalogs.en, agents: JSON.parse(deferredCatalog).agents };
