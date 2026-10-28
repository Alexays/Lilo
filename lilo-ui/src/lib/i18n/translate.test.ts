import assert from "node:assert/strict";
import { test } from "node:test";
import { catalogs, loadCatalog, resolveLocale, SUPPORTED_LOCALES, translate, type Locale } from "./translate";

for (const { code } of SUPPORTED_LOCALES) await loadCatalog(code);

test("translate returns the string for the active locale", () => {
	assert.equal(translate("en", "common.cancel"), "Cancel");
	assert.equal(translate("fr", "common.cancel"), "Annuler");
	assert.equal(translate("es", "common.cancel"), "Cancelar");
	assert.equal(translate("ru", "common.cancel"), "Отмена");
	assert.equal(translate("pt-BR", "common.cancel"), "Cancelar");
	assert.equal(translate("zh-Hans", "common.cancel"), "取消");
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
		["pt", "pt-BR"],
		["pt-BR", "pt-BR"],
		["PT-br", "pt-BR"],
		["pt-PT", "pt-BR"],
		["pt-AO", "pt-BR"],
		["en-US", "en"],
		["ru", "ru"],
		["ru-RU", "ru"],
		["ru-BY", "ru"],
		["RU-KZ", "ru"],
		["es", "es"],
		["es-ES", "es"],
		["es-MX", "es"],
		["ES-419", "es"],
		["zh", "zh-Hans"],
		["zh-CN", "zh-Hans"],
		["zh-SG", "zh-Hans"],
		["zh-Hans", "zh-Hans"],
		["ZH-HANS-CN", "zh-Hans"],
		["zh-Hans-HK", "zh-Hans"],
		["zh-Hant", "en"],
		["zh-TW", "en"],
		["zh-HK", "en"],
		["zh-MO", "en"],
		["zh-Hant-CN", "en"],
		["ar-SA", "en"],
		["", "en"],
		[null, "en"],
		[undefined, "en"],
	];
	for (const [tag, expected] of cases) {
		assert.equal(resolveLocale(tag), expected, `resolveLocale(${tag})`);
	}
});

function flatten(obj: Record<string, unknown>, prefix = ""): Array<[string, unknown]> {
	return Object.entries(obj).flatMap(([key, value]) =>
		typeof value === "object" && value !== null && !("other" in value)
			? flatten(value as Record<string, unknown>, `${prefix}${key}.`)
			: [[`${prefix}${key}`, value] as [string, unknown]],
	);
}

test("every catalog exposes the same keys and placeholders as English", () => {
	const english = new Map(flatten(catalogs.en));
	const placeholders = (value: string) => [...value.matchAll(/\{\w+\}|%[-+\d.#]*[@a-zA-Z%]/g)].map(([match]) => match).sort();
	for (const { code } of SUPPORTED_LOCALES) {
		const catalog = new Map(flatten(catalogs[code] ?? {}));
		assert.deepEqual([...catalog.keys()].sort(), [...english.keys()].sort(), `${code}.json must define the same keys as en.json`);
		for (const [key, source] of english) {
			const value = catalog.get(key);
			assert.equal(typeof value, typeof source, `${code}.${key}`);
			const plural = typeof source === "object" && source !== null;
			if (plural) {
				const expected = new Intl.PluralRules(code).resolvedOptions().pluralCategories.includes("few")
					? new Intl.PluralRules(code).resolvedOptions().pluralCategories
					: Object.keys(source);
				assert.deepEqual(Object.keys(value as object).sort(), expected.sort(), `${code}.${key}`);
			}
			const forms = plural ? Object.values(value as object) : [value];
			const template = plural ? (source as Record<string, string>).other : source as string;
			for (const form of forms) {
				assert.equal(typeof form, "string", `${code}.${key} must be a string`);
				assert.ok((form as string).trim(), `${code}.${key} must not be empty`);
				assert.deepEqual(placeholders(form as string), placeholders(template), `${code}.${key} must preserve placeholders`);
			}
		}
	}
});

test("Simplified Chinese uses the same plural form for all counts and groups digits", () => {
	assert.equal(translate("zh-Hans", "onboarding.import.count.tabs", { count: 0 }), "0 个打开的标签页");
	assert.equal(translate("zh-Hans", "onboarding.import.count.tabs", { count: 1 }), "1 个打开的标签页");
	assert.equal(translate("zh-Hans", "onboarding.import.count.tabs", { count: 12345 }), "12,345 个打开的标签页");
});

test("Spanish uses singular only for one and formats counts with Spanish separators", () => {
	assert.equal(translate("es", "onboarding.import.count.tabs", { count: 0 }), "0 pestañas abiertas");
	assert.equal(translate("es", "onboarding.import.count.tabs", { count: 1 }), "1 pestaña abierta");
	assert.equal(translate("es", "onboarding.import.count.tabs", { count: 12345 }), "12.345 pestañas abiertas");
});

test("Brazilian Portuguese counts use local grouping and plural forms", () => {
	assert.equal(translate("pt-BR", "onboarding.import.count.bookmarks", { count: 0 }), "0 favorito");
	assert.equal(translate("pt-BR", "onboarding.import.count.bookmarks", { count: 1 }), "1 favorito");
	assert.equal(translate("pt-BR", "onboarding.import.count.bookmarks", { count: 2 }), "2 favoritos");
	assert.equal(translate("pt-BR", "onboarding.import.count.bookmarks", { count: 12345 }), "12.345 favoritos");
	assert.equal(translate("pt-BR", "onboarding.import.count.bookmarks", { count: 1000000 }), "1.000.000 favoritos");
	assert.equal(translate("pt-BR", "settings.extensionUpdates.updated", { count: 1 }), "1 atualizada");
	assert.equal(translate("pt-BR", "settings.extensionUpdates.updated", { count: 2 }), "2 atualizadas");
});

test("Russian counts use one, few, many and fractional forms with local number formatting", () => {
	for (const [count, expected] of [
		[0, "0 открытых вкладок"],
		[1, "1 открытая вкладка"],
		[2, "2 открытые вкладки"],
		[5, "5 открытых вкладок"],
		[11, "11 открытых вкладок"],
		[14, "14 открытых вкладок"],
		[21, "21 открытая вкладка"],
		[22, "22 открытые вкладки"],
		[25, "25 открытых вкладок"],
		[111, "111 открытых вкладок"],
		[12345, "12 345 открытых вкладок"],
		[1.5, "1,5 открытой вкладки"],
	] as const) {
		assert.equal(translate("ru", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected);
	}
	assert.equal(translate("ru", "settings.extensionUpdates.available", { count: 22 }), "Доступно 22 обновления");
});

test("Ukrainian regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["uk", "uk-UA", "UK-ua"]) {
		assert.equal(resolveLocale(tag), "uk", tag);
	}
	assert.equal(translate("uk", "common.cancel"), "Скасувати");
	for (const [count, expected] of [
		[0, "0 відкритих вкладок"],
		[1, "1 відкрита вкладка"],
		[2, "2 відкриті вкладки"],
		[5, "5 відкритих вкладок"],
		[11, "11 відкритих вкладок"],
		[12, "12 відкритих вкладок"],
		[14, "14 відкритих вкладок"],
		[21, "21 відкрита вкладка"],
		[22, "22 відкриті вкладки"],
		[25, "25 відкритих вкладок"],
		[101, "101 відкрита вкладка"],
		[112, "112 відкритих вкладок"],
		[12345, "12 345 відкритих вкладок"],
		[1.5, "1,5 відкритої вкладки"],
	] as const) {
		assert.equal(translate("uk", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});

test("German regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["de", "de-DE", "DE-at", "de-CH"]) {
		assert.equal(resolveLocale(tag), "de", tag);
	}
	assert.equal(translate("de", "common.cancel"), "Abbrechen");
	for (const [count, expected] of [
		[0, "0 offene Tabs"],
		[1, "1 offener Tab"],
		[2, "2 offene Tabs"],
		[5, "5 offene Tabs"],
		[21, "21 offene Tabs"],
		[12345, "12.345 offene Tabs"],
		[1.5, "1,5 offene Tabs"],
	] as const) {
		assert.equal(translate("de", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});
