import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

test.use({ locale: "de-CH", viewport: { width: 600, height: 400 } });

test("German follows the system language and persists changes", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	const language = page.getByRole("combobox", { name: "Sprache", exact: true });
	await expect(language).toHaveValue("de");
	await expect(language.locator("option:checked")).toHaveText("Deutsch");
	await language.selectOption("en");
	await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
	expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "en")).toBe(true);
	await page.getByRole("combobox", { name: "Language", exact: true }).selectOption("de");
	await expect(page.getByRole("combobox", { name: "Sprache", exact: true })).toHaveValue("de");
	expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "de")).toBe(true);
});

test("a saved German choice overrides the system language", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "en" } });
		window.__lilo!.receive({ event: "openSettings" });
	});
	await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "de" } }));
	await expect(page.getByRole("combobox", { name: "Sprache", exact: true })).toHaveValue("de");
});

for (const colorScheme of ["light", "dark"] as const) {
	test("German settings fit the minimum window in " + colorScheme, async ({ page }, testInfo) => {
		await page.emulateMedia({ colorScheme });
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		for (const section of ["Terminal", "Allgemein", "Erscheinungsbild", "Tabs und Spaces", "Audio und Video", "Datenschutz", "Erweitert", "KI-Agenten"]) {
			await page.getByRole("button", { name: section, exact: true }).click();
			const rows = page.locator(".ui-shell-frame .ui-list-row:has(.ui-list-row-action)");
			await expect(rows.first()).toBeVisible();
			for (const row of await rows.all()) {
				const title = row.locator(".ui-list-row-title");
				const copy = (await row.locator(".ui-list-row-copy").boundingBox())!;
				const action = (await row.locator(".ui-list-row-action").boundingBox())!;
				const overlaps = copy.x + copy.width > action.x && action.y < copy.y + copy.height && copy.y < action.y + action.height;
				expect(overlaps, `${section}: ${await title.textContent()}`).toBe(false);
				expect(await title.evaluate((el) => el.scrollWidth <= el.clientWidth), `${section}: ${await title.textContent()}`).toBe(true);
			}
		}
		await page.getByRole("button", { name: "Allgemein", exact: true }).click();
		await expect(page.getByRole("combobox", { name: "Sprache", exact: true })).toBeVisible();
		await page.screenshot({ path: testInfo.outputPath(`settings-${colorScheme}.png`), animations: "disabled" });
	});
}
