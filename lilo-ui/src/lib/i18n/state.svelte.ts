// Reactive locale state. `t()` reads the `current` rune, so every component that calls it
// re-renders when the locale changes: switching language is instant, no reload.

import { type Locale, loadCatalog, translate } from "./translate";

// English until main.ts applies the interface language from the bootstrap script; a persisted setting can override it later.
let current = $state<Locale>("en");
let requested: Locale = "en";
// The language with the user's region (from native), for Intl: "en" with region GB formats "15:05", not "3:05 PM".
let formatLocale = $state("en");
let region: string | undefined;

function withRegion(locale: Locale): string {
	if (!region) return locale;
	try {
		return new Intl.Locale(locale, { region }).toString();
	} catch {
		return locale;
	}
}

/** The catalog's language code: the key for anything translated per language. */
export function getLocale(): Locale {
	return current;
}

/** The locale tag for Intl formatters (dates, numbers, lists): the language refined by the user's region. */
export function getFormatLocale(): string {
	return formatLocale;
}

export function setRegion(value: string | undefined): void {
	if (value === region) return;
	region = value;
	formatLocale = withRegion(current);
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
	if (requested !== locale) return;
	current = loaded;
	formatLocale = withRegion(loaded);
	document.documentElement.lang = loaded;
}

/** Translate `key` for the active locale. Reactive: re-evaluates when the locale changes. */
export function t(key: string, params?: Record<string, string | number>): string {
	return translate(current, key, params);
}
