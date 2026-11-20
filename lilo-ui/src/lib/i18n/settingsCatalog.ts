import deferredCatalog from "./locales/en.json?raw";
import { catalogs } from "./translate";

// Settings' English copy is left out of the chrome's first frame: every settings surface imports this
// module, so it loads with the first one shown.
catalogs.en = { ...catalogs.en, settings: JSON.parse(deferredCatalog).settings };
