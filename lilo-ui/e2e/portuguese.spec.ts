import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

test.use({ viewport: { width: 600, height: 400 } });

test.describe("Portuguese language choice", () => {
	test.use({ locale: "en-US" });

	test("switches immediately, persists the choice, and restores it from settings", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		await page.getByRole("combobox", { name: "Language", exact: true }).selectOption("pt-BR");

		await expect(page.locator(".ui-shell-frame-title")).toHaveText("Geral");
		await expect(page.getByRole("combobox", { name: "Idioma", exact: true })).toHaveValue("pt-BR");
		expect(await sentCommands(page)).toContainEqual({ action: "setSetting", payload: { key: "locale", value: "pt-BR" } });

		await page.getByRole("combobox", { name: "Idioma", exact: true }).selectOption("en");
		await expect(page.locator(".ui-shell-frame-title")).toHaveText("General");
		await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "pt-BR" } }));
		await expect(page.locator(".ui-shell-frame-title")).toHaveText("Geral");
		await expect(page.getByRole("combobox", { name: "Idioma", exact: true })).toHaveValue("pt-BR");
	});
});

test.describe("Brazilian Portuguese at the minimum window size", () => {
	test.use({ locale: "pt-BR" });

	test("follows the system language and keeps settings labels clear of their controls", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		await expect(page.locator(".ui-shell-frame-title")).toHaveText("Geral");
		await page.evaluate(() => window.__lilo!.receive({
			event: "settingsLoaded",
			settings: { agentControlEnabled: "true", terminalLidClosed: "true" },
		}));

		for (const section of ["Geral", "Aparência", "Abas e espaços", "Privacidade", "Terminal", "Agentes de IA", "Avançado"]) {
			await page.locator(".section-nav-button").filter({ hasText: section }).click();
			const rows = page.locator(".ui-shell-frame .ui-list-row:has(.ui-list-row-action)");
			await expect(rows.first()).toBeVisible();
			for (const row of await rows.all()) {
				const title = row.locator(".ui-list-row-title");
				const copy = (await row.locator(".ui-list-row-copy").boundingBox())!;
				const action = (await row.locator(".ui-list-row-action").boundingBox())!;
				const box = (await row.boundingBox())!;
				const controls = await row.locator(".ui-list-row-action > *").evaluateAll((els) =>
					Math.max(...els.map((el) => el.getBoundingClientRect().right)));
				const label = `${section}: ${await title.textContent()}`;
				const overlaps = copy.x + copy.width > action.x && action.y < copy.y + copy.height && copy.y < action.y + action.height;
				expect(overlaps, label).toBe(false);
				expect(controls, label).toBeLessThanOrEqual(box.x + box.width + 1);
				expect(await title.evaluate((el) => el.scrollWidth <= el.clientWidth), label).toBe(true);
			}
		}
	});
});
