import { expect, type Page, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

test.use({ locale: "fr-FR" });

test("in a small window the find bar stays over the page, clear of the sidebar", async ({ page }) => {
	await page.setViewportSize({ width: 600, height: 400 });
	await bootChrome(page, initialWorld());
	const findBar = page.locator(".find-bar");
	// The find bar mounts with the deferred chrome, a beat after boot.
	await expect(async () => {
		await page.evaluate(() => window.__lilo!.receive({ event: "toggleFindBar", query: "introuvable" }));
		await expect(findBar).toBeVisible({ timeout: 200 });
	}).toPass();
	await page.evaluate(() => window.__lilo!.receive({ event: "findInPageResult", query: "introuvable", matchFound: false }));
	await expect(page.locator(".find-status")).toHaveText("Aucun résultat");

	const sidebar = (await page.locator(".sidebar").boundingBox())!;
	const bar = (await findBar.boundingBox())!;
	expect(bar.x).toBeGreaterThanOrEqual(sidebar.x + sidebar.width);
	expect(bar.x + bar.width).toBeLessThanOrEqual(600);
	for (const button of await page.locator(".find-bar .find-btn").all()) {
		const box = (await button.boundingBox())!;
		expect(box.width).toBe(24);
		expect(box.x + box.width).toBeLessThanOrEqual(bar.x + bar.width);
	}
});

test("Escape closing the find bar hands the keyboard back to the page", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const findBar = page.locator(".find-bar");
	await expect(async () => {
		await page.evaluate(() => window.__lilo!.receive({ event: "toggleFindBar", query: "x" }));
		await expect(findBar).toBeVisible({ timeout: 200 });
	}).toPass();

	await page.keyboard.press("Escape");

	await expect(findBar).toBeHidden();
	expect((await sentCommands(page)).map((c) => c.action)).toContain("focusPage");
});

test("the previous, next and close buttons draw icons, not text glyphs", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await expect(async () => {
		await page.evaluate(() => window.__lilo!.receive({ event: "toggleFindBar", query: "x" }));
		await expect(page.locator(".find-bar")).toBeVisible({ timeout: 200 });
	}).toPass();

	for (const name of ["Résultat précédent", "Résultat suivant", "Fermer la barre de recherche"]) {
		const button = page.getByRole("button", { name });
		await expect(button.locator("svg")).toHaveCount(1);
		await expect(button).toHaveText("");
	}
});

async function openFindBar(page: Page, query?: string): Promise<void> {
	await bootChrome(page, initialWorld());
	await expect(async () => {
		await page.evaluate((query) => window.__lilo!.receive({ event: "toggleFindBar", query }), query);
		await expect(page.locator(".find-bar")).toBeVisible({ timeout: 200 });
	}).toPass();
}

test("the query keeps its spaces, as in Chrome", async ({ page }) => {
	await openFindBar(page);
	await page.getByRole("textbox", { name: "Rechercher dans la page" }).fill("cat ");
	await expect
		.poll(async () => (await sentCommands(page)).filter((c) => c.action === "findInPage").at(-1)?.payload.query)
		.toBe("cat ");
});

test("the next opening brings the last query back, selected", async ({ page }) => {
	await openFindBar(page, "beta");
	const input = page.getByRole("textbox", { name: "Rechercher dans la page" });
	await input.press("Escape");
	await expect(page.locator(".find-bar")).toBeHidden();

	await page.evaluate(() => window.__lilo!.receive({ event: "toggleFindBar" }));
	await expect(input).toHaveValue("beta");
	await expect.poll(() => input.evaluate((el: HTMLInputElement) => [el.selectionStart, el.selectionEnd])).toEqual([0, 4]);
});
