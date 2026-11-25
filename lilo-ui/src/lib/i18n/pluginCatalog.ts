import deferredCatalog from "./locales/en.json?raw";
import { catalogs } from "./translate";

// The plugin panel's English copy is left out of the chrome's first frame: the panel loads with the
// first settings surface, the way the settings copy does.
catalogs.en = { ...catalogs.en, plugins: JSON.parse(deferredCatalog).plugins };
