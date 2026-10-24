// Reactive locale state. `t()` reads the `current` rune, so every component that calls it
// re-renders when the locale changes: switching language is instant, no reload.

import { type Locale, loadCatalog, translate } from "./translate";

// English until main.ts applies the WKWebView's system language; a persisted setting can override it later.
let current = $state<Locale>("en");
let requested: Locale = "en";

export function getLocale(): Locale {
	return current;
}

/** Switches once the locale's catalog is loaded, English when it cannot be; the latest call wins. Never rejects. */
export async function setLocale(locale: Locale): Promise<void> {
	requested = locale;
	let loaded = locale;
	try {
		await loadCatalog(locale);
	} catch (error) {
		console.error(`Could not load the ${locale} catalog`, error);
		loaded = "en";
	}
	if (requested === locale) current = loaded;
}

/** Translate `key` for the active locale. Reactive: re-evaluates when the locale changes. */
export function t(key: string, params?: Record<string, string | number>): string {
	return translate(current, key, params);
}
