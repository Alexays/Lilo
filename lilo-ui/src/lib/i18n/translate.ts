// Tiny dependency-free i18n core. Pure functions only (unit-tested in translate.test.ts);
// the reactive current-locale state lives in ./state.svelte.ts.

import en from "./locales/en.json";

export type Locale = "en" | "fr" | "es";

export const SUPPORTED_LOCALES = [
	{ code: "en", label: "English" },
	{ code: "fr", label: "Français" },
	{ code: "es", label: "Español" },
] as const satisfies ReadonlyArray<{ code: Locale; label: string }>;

type Messages = Record<string, unknown>;

// English is the source catalog and the fallback for any key a locale hasn't translated.
// Other catalogs load on demand (loadCatalog) to keep them out of the entry chunk.
export const catalogs: { en: Messages } & Partial<Record<Locale, Messages>> = { en };

export async function loadCatalog(locale: Locale): Promise<void> {
	if (locale === "fr") catalogs.fr ??= (await import("./locales/fr.json")).default;
	if (locale === "es") catalogs.es ??= (await import("./locales/es.json")).default;
}

export function isSupportedLocale(value: string): value is Locale {
	return SUPPORTED_LOCALES.some((entry) => entry.code === value);
}

/** Map a BCP-47 tag ("fr-FR", "en-US") to a supported locale, defaulting to English. */
export function resolveLocale(tag: string | null | undefined): Locale {
	const primary = (tag ?? "").toLowerCase().split("-")[0];
	return isSupportedLocale(primary) ? primary : "en";
}

// Flattened once per catalog object so t() is a single Map lookup.
const flatCatalogs = new WeakMap<Messages, Map<string, string>>();

function flattenInto(flat: Map<string, string>, node: Messages, prefix: string): void {
	for (const [key, value] of Object.entries(node)) {
		if (typeof value === "string") flat.set(prefix + key, value);
		else if (typeof value === "object" && value !== null) flattenInto(flat, value as Messages, `${prefix}${key}.`);
	}
}

function flatCatalog(catalog: Messages): Map<string, string> {
	let flat = flatCatalogs.get(catalog);
	if (!flat) {
		flat = new Map();
		flattenInto(flat, catalog, "");
		flatCatalogs.set(catalog, flat);
	}
	return flat;
}

const pluralRules = new Map<Locale, Intl.PluralRules>();
const countFormats = new Map<Locale, Intl.NumberFormat>();

function cached<T>(cache: Map<Locale, T>, locale: Locale, make: () => T): T {
	let value = cache.get(locale);
	if (!value) {
		value = make();
		cache.set(locale, value);
	}
	return value;
}

function interpolate(locale: Locale, template: string, params: Record<string, string | number>): string {
	return template.replace(/\{(\w+)\}/g, (match, name: string) => {
		if (!(name in params)) return match;
		const value = params[name];
		return name === "count" && typeof value === "number"
			? cached(countFormats, locale, () => new Intl.NumberFormat(locale)).format(value)
			: String(value);
	});
}

/**
 * Resolve `key` for `locale`, falling back to English, then to the key itself so a missing
 * translation is visible rather than blank. `{name}` placeholders are filled from `params`.
 * A numeric `count` picks the key's plural form (`key.one`, `key.other`...) and is digit-grouped.
 */
export function translate(
	locale: Locale,
	key: string,
	params?: Record<string, string | number>,
): string {
	const lookup = (candidate: string) =>
		flatCatalog(catalogs[locale] ?? catalogs.en).get(candidate) ?? flatCatalog(catalogs.en).get(candidate);
	const count = params?.count;
	const plural = typeof count === "number"
		? `${key}.${cached(pluralRules, locale, () => new Intl.PluralRules(locale)).select(count)}`
		: null;
	const template = (plural && (lookup(plural) ?? lookup(`${key}.other`))) || lookup(key) || key;
	return params ? interpolate(locale, template, params) : template;
}
