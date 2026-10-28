import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

test.use({ locale: "IT-ch", viewport: { width: 600, height: 400 } });

test("Italian follows the system language and persists changes", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	const language = page.getByRole("combobox", { name: "Lingua", exact: true });
	await expect(language).toHaveValue("it");
	await expect(language.locator("option:checked")).toHaveText("Italiano");
	await language.selectOption("en");
	await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
	expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "en")).toBe(true);
	await page.getByRole("combobox", { name: "Language", exact: true }).selectOption("it");
	await expect(page.getByRole("combobox", { name: "Lingua", exact: true })).toHaveValue("it");
	expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "it")).toBe(true);
});

test("a saved Italian choice overrides the system language", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "en" } });
		window.__lilo!.receive({ event: "openSettings" });
	});
	await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "it" } }));
	await expect(page.getByRole("combobox", { name: "Lingua", exact: true })).toHaveValue("it");
});

for (const colorScheme of ["light", "dark"] as const) {
	test("Italian settings fit the minimum window in " + colorScheme, async ({ page }, testInfo) => {
		await page.emulateMedia({ colorScheme });
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		for (const section of ["Terminale", "Generali", "Aspetto", "Schede e spazi", "Audio e video", "Privacy", "Avanzate", "Agenti IA"]) {
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
		await page.getByRole("button", { name: "Generali", exact: true }).click();
		await expect(page.getByRole("combobox", { name: "Lingua", exact: true })).toBeVisible();
		await page.screenshot({ path: testInfo.outputPath(`settings-${colorScheme}.png`), animations: "disabled" });
	});
}
