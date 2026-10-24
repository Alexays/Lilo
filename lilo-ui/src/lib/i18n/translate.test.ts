import assert from "node:assert/strict";
import { test } from "node:test";
import { catalogs, loadCatalog, resolveLocale, translate, type Locale } from "./translate";

await loadCatalog("fr");

test("translate returns the string for the active locale", () => {
	assert.equal(translate("en", "common.cancel"), "Cancel");
	assert.equal(translate("fr", "common.cancel"), "Annuler");
});

test("translate falls back to English for an untranslated key", () => {
	// Swap in an en-only key so this test doesn't depend on the catalogs staying out of sync.
	const en = catalogs.en;
	catalogs.en = { ...en, __test: { onlyEnglish: "English only" } };
	assert.equal(translate("fr", "__test.onlyEnglish"), "English only");
	catalogs.en = en;
});

test("translate returns the key itself when missing everywhere", () => {
	assert.equal(translate("en", "does.not.exist"), "does.not.exist");
});

test("translate interpolates {named} placeholders", () => {
	const en = catalogs.en;
	catalogs.en = { ...en, __test: { greet: "Hello {name}, you have {count} tabs" } };
	assert.equal(
		translate("en", "__test.greet", { name: "Alex", count: 3 }),
		"Hello Alex, you have 3 tabs",
	);
	// A placeholder with no matching param is left intact rather than blanked.
	assert.equal(translate("en", "__test.greet", { name: "Alex" }), "Hello Alex, you have {count} tabs");
	catalogs.en = en;
});

test("translate picks a count's plural form and groups its digits", () => {
	const en = catalogs.en;
	const fr = catalogs.fr;
	catalogs.en = { ...en, __test: { pages: { one: "{count} page", other: "{count} pages" } } };
	catalogs.fr = { ...fr, __test: { pages: { one: "{count} page importée", other: "{count} pages importées" } } };
	assert.equal(translate("en", "__test.pages", { count: 1 }), "1 page");
	assert.equal(translate("en", "__test.pages", { count: 0 }), "0 pages");
	assert.equal(translate("en", "__test.pages", { count: 12345 }), "12,345 pages");
	// French puts 0 and 1 in the singular, and a million in "many", which falls back to "other".
	assert.equal(translate("fr", "__test.pages", { count: 0 }), "0 page importée");
	assert.equal(translate("fr", "__test.pages", { count: 1000000 }).replace(/\s/g, " "), "1 000 000 pages importées");
	catalogs.en = en;
	catalogs.fr = fr;
});

test("resolveLocale maps BCP-47 tags to a supported locale, defaulting to English", () => {
	const cases: Array<[string | null | undefined, Locale]> = [
		["fr-FR", "fr"],
		["fr", "fr"],
		["en-US", "en"],
		["de-DE", "en"],
		["", "en"],
		[null, "en"],
		[undefined, "en"],
	];
	for (const [tag, expected] of cases) {
		assert.equal(resolveLocale(tag), expected, `resolveLocale(${tag})`);
	}
});

test("en and fr catalogs expose the same set of keys", () => {
	const flatten = (obj: Record<string, unknown>, prefix = ""): string[] =>
		Object.entries(obj).flatMap(([key, value]) =>
			typeof value === "object" && value !== null
				? flatten(value as Record<string, unknown>, `${prefix}${key}.`)
				: [`${prefix}${key}`],
		);
	const enKeys = flatten(catalogs.en).sort();
	const frKeys = flatten(catalogs.fr ?? {}).sort();
	assert.deepEqual(frKeys, enKeys, "fr.json and en.json must define identical keys");
});
