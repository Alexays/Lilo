import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";
import type { Locale } from "../src/lib/i18n/translate";

// The setting's label and the language's own name are written out, not read from the catalogs,
// so a wrong catalog entry fails here. System tags come in odd casings and regions on purpose.
const LANGUAGES: { system: string; code: Locale; label: string; name: string }[] = [
	{ system: "de-CH", code: "de", label: "Sprache", name: "Deutsch" },
	{ system: "IT-ch", code: "it", label: "Lingua", name: "Italiano" },
	{ system: "JA-jp", code: "ja", label: "言語", name: "日本語" },
	{ system: "KO-kr", code: "ko", label: "언어", name: "한국어" },
	{ system: "NL-be", code: "nl", label: "Taal", name: "Nederlands" },
	{ system: "PL-pl", code: "pl", label: "Język", name: "Polski" },
	{ system: "TR-tr", code: "tr", label: "Dil", name: "Türkçe" },
	{ system: "UK-ua", code: "uk", label: "Мова", name: "Українська" },
	{ system: "zh-Hant-CN", code: "zh-Hant", label: "語言", name: "繁體中文" },
	{ system: "pt-BR", code: "pt-BR", label: "Idioma", name: "Português (Brasil)" },
];

const SECTIONS = ["terminal", "general", "appearance", "tabs", "media", "privacy", "advanced", "agents"];

for (const { system, code, label, name } of LANGUAGES) {
	test.describe(`${name} as the system language`, () => {
		test.use({ locale: system, viewport: { width: 600, height: 400 } });

		test("follows the system language and persists changes", async ({ page }) => {
			const sentLocale = async (value: string) => (await sentCommands(page)).some((command) =>
				command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === value);
			await bootChrome(page, initialWorld());
			await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
			const language = page.getByRole("combobox", { name: label, exact: true });
			await expect(language).toHaveValue(code);
			await expect(language.locator("option:checked")).toHaveText(name);
			await language.selectOption("en");
			await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
			expect(await sentLocale("en")).toBe(true);
			await page.getByRole("combobox", { name: "Language", exact: true }).selectOption(code);
			await expect(language).toHaveValue(code);
			expect(await sentLocale(code)).toBe(true);
		});

		test("a saved choice overrides the system language", async ({ page }) => {
			await bootChrome(page, initialWorld());
			await page.evaluate(() => {
				window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "en" } });
				window.__lilo!.receive({ event: "openSettings" });
			});
			await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
			await page.evaluate((code) => window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: code } }), code);
			await expect(page.getByRole("combobox", { name: label, exact: true })).toHaveValue(code);
		});

		for (const colorScheme of ["light", "dark"] as const) {
			test(`settings fit the minimum window in ${colorScheme}`, async ({ page }) => {
				const catalog = await import(`../src/lib/i18n/locales/${code}.json`, { with: { type: "json" } });
				const sections: Record<string, string> = catalog.default.settings.sections;
				await page.emulateMedia({ colorScheme });
				await bootChrome(page, initialWorld());
				await page.evaluate(() => {
					window.__lilo!.receive({ event: "settingsLoaded", settings: { agentControlEnabled: "true", terminalLidClosed: "true" } });
					window.__lilo!.receive({ event: "openSettings" });
				});
				for (const section of SECTIONS.map((key) => sections[key])) {
					await page.getByRole("button", { name: section, exact: true }).click();
					const rows = page.locator(".ui-shell-frame .ui-list-row:has(.ui-list-row-action)");
					await expect(rows.first()).toBeVisible();
					for (const row of await rows.all()) {
						const title = row.locator(".ui-list-row-title");
						const copy = (await row.locator(".ui-list-row-copy").boundingBox())!;
						const action = (await row.locator(".ui-list-row-action").boundingBox())!;
						const box = (await row.boundingBox())!;
						const controls = await row.locator(".ui-list-row-action > *").evaluateAll((els) =>
							Math.max(...els.map((el) => el.getBoundingClientRect().right)));
						const where = `${section}: ${await title.textContent()}`;
						const overlaps = copy.x + copy.width > action.x && action.y < copy.y + copy.height && copy.y < action.y + action.height;
						expect(overlaps, where).toBe(false);
						expect(controls, where).toBeLessThanOrEqual(box.x + box.width + 1);
						expect(await title.evaluate((el) => el.scrollWidth <= el.clientWidth), where).toBe(true);
					}
				}
				await page.getByRole("button", { name: sections.general, exact: true }).click();
				await expect(page.getByRole("combobox", { name: label, exact: true })).toBeVisible();
			});
		}
	});
}
