import assert from "node:assert/strict";
import { test } from "node:test";
import { parseMessage, type Part } from "./icu";
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
	catalogs.en = { ...en, __test: { pages: "{count, plural, one{# page} other{# pages}}" } };
	catalogs.fr = { ...fr, __test: { pages: "{count, plural, one{# page importée} other{# pages importées}}" } };
	assert.equal(translate("en", "__test.pages", { count: 1 }), "1 page");
	assert.equal(translate("en", "__test.pages", { count: 0 }), "0 pages");
	assert.equal(translate("en", "__test.pages", { count: 12345 }), "12,345 pages");
	// French puts 0 and 1 in the singular, and a million in "many", which falls back to "other".
	assert.equal(translate("fr", "__test.pages", { count: 0 }), "0 page importée");
	assert.equal(translate("fr", "__test.pages", { count: 1000000 }).replace(/\s/g, " "), "1 000 000 pages importées");
	catalogs.en = en;
	catalogs.fr = fr;
});

test("translate renders nested select inside a plural option", () => {
	const en = catalogs.en;
	catalogs.en = {
		...en,
		__test: { items: "{count, plural, one{{kind, select, tab{# tab} other{# item}}} other{# items}}" },
	};
	assert.equal(translate("en", "__test.items", { count: 1, kind: "tab" }), "1 tab");
	assert.equal(translate("en", "__test.items", { count: 1, kind: "window" }), "1 item");
	assert.equal(translate("en", "__test.items", { count: 3, kind: "tab" }), "3 items");
	catalogs.en = en;
});

test("selectordinal picks the ordinal category, not the cardinal one", () => {
	const en = catalogs.en;
	catalogs.en = { ...en, __test: { rank: "{n, selectordinal, one{#st} two{#nd} few{#rd} other{#th}}" } };
	const ranks = [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111].map((n) => translate("en", "__test.rank", { n }));
	assert.deepEqual(ranks, ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th"]);
	catalogs.en = en;
});

test("malformed ICU patterns fall back to the literal message, never blank or wrong output", () => {
	const en = catalogs.en;
	catalogs.en = {
		...en,
		__test: {
			unbalanced: "Open {count, plural, one{# tab",
			unknownTag: "Done {count, sparkle, one{#}}",
			noOther: "{count, plural, one{# tab}}",
			badSelector: "{count, plural, bogus{# tab} other{# tabs}}",
		},
	};
	assert.equal(translate("en", "__test.unbalanced", { count: 1 }), "Open {count, plural, one{# tab");
	assert.equal(translate("en", "__test.unknownTag", { count: 1 }), "Done {count, sparkle, one{#}}");
	assert.equal(translate("en", "__test.noOther", { count: 2 }), "{count, plural, one{# tab}}");
	// An unknown selector is a valid option ICU-wise (ignored at render); a count that
	// misses it still lands on `other`.
	assert.equal(translate("en", "__test.badSelector", { count: 4 }), "4 tabs");
	catalogs.en = en;
});

test("non-numeric and missing plural arguments select the other form", () => {
	const en = catalogs.en;
	catalogs.en = { ...en, __test: { tabs: "{count, plural, one{# tab} other{# tabs}}" } };
	assert.equal(translate("en", "__test.tabs", { count: "2" as unknown as number }), "NaN tabs");
	assert.equal(translate("en", "__test.tabs"), "NaN tabs");
	catalogs.en = en;
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
		["zh-Hant", "zh-Hant"],
		["zh-TW", "zh-Hant"],
		["zh-HK", "zh-Hant"],
		["zh-MO", "zh-Hant"],
		["zh-Hant-CN", "zh-Hant"],
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

// Argument names referenced by a message part tree (`#` is the plural's count, not an arg).
function argsOf(parts: Part[]): string[] {
	const names: string[] = [];
	for (const part of parts) {
		if (typeof part === "string" || "pound" in part) continue;
		names.push(part.arg);
		if ("options" in part) for (const [, body] of part.options) names.push(...argsOf(body));
	}
	return [...new Set(names)].sort();
}

test("every catalog exposes the same keys and placeholders as English", () => {
	const english = new Map(flatten(catalogs.en));
	const placeholders = (value: string) => [...value.matchAll(/\{\w+\}|%[-+\d.#]*[@a-zA-Z%]/g)].map(([match]) => match).sort();
	for (const { code } of SUPPORTED_LOCALES) {
		const catalog = new Map(flatten(catalogs[code] ?? {}));
		assert.deepEqual([...catalog.keys()].sort(), [...english.keys()].sort(), `${code}.json must define the same keys as en.json`);
		const cldr = new Intl.PluralRules(code).resolvedOptions().pluralCategories;
		// Selectors a locale may carry: every CLDR keyword (even ones the locale never
		// selects, like zh's "one") plus exact `=N` matches and the required `other`.
		const keywords = new Set(["zero", "one", "two", "few", "many", "other"]);
		for (const [key, source] of english) {
			const value = catalog.get(key);
			assert.equal(typeof value, typeof source, `${code}.${key}`);
			if (typeof source === "object" && source !== null) {
				// native.* plural dicts stay objects for String(format:); keep their category rule.
				const expected = cldr.includes("few") ? cldr : Object.keys(source);
				assert.deepEqual(Object.keys(value as object).sort(), expected.sort(), `${code}.${key}`);
				for (const form of Object.values(value as object)) {
					assert.equal(typeof form, "string", `${code}.${key} must be a string`);
					assert.deepEqual(placeholders(form as string), placeholders((source as Record<string, string>).other), `${code}.${key} must preserve placeholders`);
				}
				continue;
			}
			assert.equal(typeof value, "string", `${code}.${key}`);
			assert.ok((value as string).trim(), `${code}.${key} must not be empty`);
			const enParts = parseMessage(source as string);
			const parts = parseMessage(value as string);
			const structured = enParts.filter((p) => typeof p === "object" && "kind" in p);
			if (!structured.length) {
				// Plain message: placeholder parity, printf tokens included (native.* strings).
				assert.deepEqual(placeholders(value as string), placeholders(source as string), `${code}.${key} must preserve placeholders`);
				continue;
			}
			// ICU message: same arguments overall, same plural/select elements, selectors valid
			// for the locale's CLDR categories, `other` present, and every option keeps the
			// placeholders of the English `other` option.
			assert.deepEqual(argsOf(parts), argsOf(enParts), `${code}.${key} must preserve arguments`);
			for (const enEl of structured) {
				if (!("options" in enEl)) continue;
				const el = parts.find(
					(p): p is Extract<Part, { kind: string }> =>
						typeof p === "object" && "kind" in p && p.arg === enEl.arg && p.kind === enEl.kind,
				);
				assert.ok(el && "options" in el, `${code}.${key}: missing ${enEl.kind} on {${enEl.arg}}`);
				const enOther = enEl.options.find(([sel]) => sel === "other");
				assert.ok(enOther, `${code}.${key}: English needs an "other" option`);
				for (const [sel, body] of el.options) {
					const valid = /^=\d+$/.test(sel)
						|| (enEl.kind === "select" ? sel === "other" || !keywords.has(sel) : keywords.has(sel));
					assert.ok(valid, `${code}.${key}: selector "${sel}" is not a plural keyword`);
					assert.deepEqual(argsOf(body), argsOf(enOther[1]), `${code}.${key} ${sel}: placeholders must match the English "other" option`);
				}
				assert.ok(el.options.some(([sel]) => sel === "other"), `${code}.${key}: needs an "other" option`);
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
	assert.equal(translate("ru", "processManager.tabsCount", { count: 21 }), "21 вкладка");
	assert.equal(translate("ru", "agents.row.linesAdded", { count: 5 }), "5 строк добавлено");
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

test("Japanese regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["ja", "ja-JP", "JA-jp"]) {
		assert.equal(resolveLocale(tag), "ja", tag);
	}
	assert.equal(translate("ja", "common.cancel"), "キャンセル");
	for (const [count, expected] of [
		[0, "開いているタブ0個"],
		[1, "開いているタブ1個"],
		[2, "開いているタブ2個"],
		[5, "開いているタブ5個"],
		[21, "開いているタブ21個"],
		[12345, "開いているタブ12,345個"],
		[1.5, "開いているタブ1.5個"],
	] as const) {
		assert.equal(translate("ja", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});

test("Italian regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["it", "it-IT", "IT-ch"]) {
		assert.equal(resolveLocale(tag), "it", tag);
	}
	assert.equal(translate("it", "common.cancel"), "Annulla");
	for (const [count, expected] of [
		[0, "0 schede aperte"],
		[1, "1 scheda aperta"],
		[2, "2 schede aperte"],
		[5, "5 schede aperte"],
		[21, "21 schede aperte"],
		[12345, "12.345 schede aperte"],
		[1.5, "1,5 schede aperte"],
	] as const) {
		assert.equal(translate("it", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});

test("Korean regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["ko", "ko-KR", "KO-kr"]) {
		assert.equal(resolveLocale(tag), "ko", tag);
	}
	assert.equal(translate("ko", "common.cancel"), "취소");
	for (const [count, expected] of [
		[0, "열린 탭 0개"],
		[1, "열린 탭 1개"],
		[2, "열린 탭 2개"],
		[5, "열린 탭 5개"],
		[21, "열린 탭 21개"],
		[12345, "열린 탭 12,345개"],
		[1.5, "열린 탭 1.5개"],
	] as const) {
		assert.equal(translate("ko", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});

test("Traditional Chinese regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["zh-Hant", "zh-TW", "zh-HK", "zh-MO", "ZH-HANT-TW", "zh-Hant-CN"]) {
		assert.equal(resolveLocale(tag), "zh-Hant", tag);
	}
	assert.equal(translate("zh-Hant", "common.cancel"), "取消");
	for (const [count, expected] of [
		[0, "0 個已開啟的分頁"],
		[1, "1 個已開啟的分頁"],
		[2, "2 個已開啟的分頁"],
		[5, "5 個已開啟的分頁"],
		[21, "21 個已開啟的分頁"],
		[12345, "12,345 個已開啟的分頁"],
		[1.5, "1.5 個已開啟的分頁"],
	] as const) {
		assert.equal(translate("zh-Hant", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});

test("Polish regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["pl", "pl-PL", "PL-pl"]) {
		assert.equal(resolveLocale(tag), "pl", tag);
	}
	assert.equal(translate("pl", "common.cancel"), "Anuluj");
	for (const [count, expected] of [
		[0, "0 otwartych kart"],
		[1, "1 otwarta karta"],
		[2, "2 otwarte karty"],
		[5, "5 otwartych kart"],
		[11, "11 otwartych kart"],
		[12, "12 otwartych kart"],
		[14, "14 otwartych kart"],
		[21, "21 otwartych kart"],
		[22, "22 otwarte karty"],
		[25, "25 otwartych kart"],
		[101, "101 otwartych kart"],
		[112, "112 otwartych kart"],
		[12345, "12 345 otwartych kart"],
		[1.5, "1,5 otwartej karty"],
	] as const) {
		assert.equal(translate("pl", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});

test("Turkish regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["tr", "tr-TR", "TR-tr"]) {
		assert.equal(resolveLocale(tag), "tr", tag);
	}
	assert.equal(translate("tr", "common.cancel"), "Vazgeç");
	for (const [count, expected] of [
		[0, "0 açık sekme"],
		[1, "1 açık sekme"],
		[2, "2 açık sekme"],
		[5, "5 açık sekme"],
		[21, "21 açık sekme"],
		[12345, "12.345 açık sekme"],
		[1.5, "1,5 açık sekme"],
	] as const) {
		assert.equal(translate("tr", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});

test("Dutch regional tags, translations and count forms use the selected catalog", () => {
	for (const tag of ["nl", "nl-NL", "NL-be"]) {
		assert.equal(resolveLocale(tag), "nl", tag);
	}
	assert.equal(translate("nl", "common.cancel"), "Annuleer");
	for (const [count, expected] of [
		[0, "0 geopende tabbladen"],
		[1, "1 geopend tabblad"],
		[2, "2 geopende tabbladen"],
		[5, "5 geopende tabbladen"],
		[21, "21 geopende tabbladen"],
		[12345, "12.345 geopende tabbladen"],
		[1.5, "1,5 geopende tabbladen"],
	] as const) {
		assert.equal(translate("nl", "onboarding.import.count.tabs", { count }).replace(/\s/g, " "), expected.replace(/\s/g, " "));
	}
});
