import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1, SPACE_2 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

for (const [preset, row, text, palette] of [["default", 32, 13, 480], ["streamlined", 36, 14, 520]] as const) {
	test(`${preset} coordinates the sidebar and floating palette from saved settings`, async ({ page }) => {
		await page.emulateMedia({ reducedMotion: "reduce" });
		await bootChrome(page, { ...initialWorld(), settings: { interfaceStyle: preset } });
		await expect(page.locator("html")).toHaveAttribute("data-interface-style", preset);
		await expect(page.locator('[data-tab-id="tab-alpha"]')).toHaveCSS("height", `${row}px`);
		await expect(page.locator('[data-tab-id="tab-alpha"] .tab-title')).toHaveCSS("font-size", `${text}px`);
		await expect(page.locator(".bookmark-tile").first()).toHaveCSS("height", "48px");
		await expect(page.locator(".bookmark-tile .site-favicon").first()).toHaveCSS("width", "20px");
		await expect(page.locator(`[data-space-dnd-id="${SPACE_1}"] .space-glyph`)).toHaveCSS("width", "28px");
		await expect.poll(async () => Math.round((await page.locator(".sidebar-layout .url-trigger").boundingBox())!.height)).toBe(row);
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
		await expect(page.locator(".command-bar")).toHaveCSS("width", `${palette}px`);
		await expect(page.locator(".command-bar")).toHaveCSS("height", `${320 + (text - 13) * 24}px`);
		await expect(page.locator(".command-bar-result").first()).toHaveCSS("min-height", "48px");
		await expect(page.locator(".command-bar-input")).toHaveCSS("font-size", `${text + 4}px`);
		await expect(page.locator(".scope-picker").first()).toHaveCSS("height", "28px");
		await page.locator(".command-bar-info").click();
		await expect(page.locator(".command-bar-help .keycap").first()).toHaveCSS("height", "20px");
	});

	test(`${preset} preserves the adaptive grid when many Favorites use compact tiles`, async ({ page }) => {
		const world = initialWorld();
		world.settings = { interfaceStyle: preset };
		const favorites = Array.from({ length: 11 }, (_, index) => `favorite-${index}`);
		world.tabsBySpace[SPACE_1].push(...favorites.map((id) => tab(id, SPACE_1, { isBookmarked: true })));
		world.treeItemsBySpace[SPACE_1].push(...favorites.map((id, index) => treeItem(id, SPACE_1, 10 + index, "bookmarked")));
		await bootChrome(page, world);
		const grid = page.locator(".bookmarked-list");
		await expect(grid).toHaveClass(/compact/);
		await expect(grid.locator(".bookmark-tile")).toHaveCount(12);
		await expect(grid.locator(".bookmark-tile").first()).toHaveCSS("height", "40px");
		await expect(grid.locator(".site-favicon").first()).toHaveCSS("width", "18px");
		const tops = await grid.locator(".bookmark-tile").evaluateAll((els) => els.map((el) => Math.round(el.getBoundingClientRect().top)));
		expect([...new Set(tops)].map((top) => tops.filter((other) => other === top).length)).toEqual([4, 4, 4]);
	});

	test(`${preset} also sizes the docked New Tab palette`, async ({ page }) => {
		await page.emulateMedia({ reducedMotion: "reduce" });
		const world = initialWorld();
		world.settings = { interfaceStyle: preset };
		world.tabsBySpace[SPACE_1].push(tab("blank", SPACE_1, { url: "", title: "" }));
		world.treeItemsBySpace[SPACE_1].push(treeItem("blank", SPACE_1, 10));
		world.activeTabBySpace[SPACE_1] = "blank";
		await bootChrome(page, world);
		await expect(page.locator(".command-bar-backdrop")).toHaveClass(/docked/);
		await expect(page.locator(".command-bar")).toHaveCSS("width", `${palette}px`);
		await expect(page.locator(".command-bar")).toHaveCSS("height", `${320 + (text - 13) * 24}px`);
		await expect(page.locator(".scope-picker").first()).toHaveCSS("height", "28px");
		await expect(page.locator(".command-bar-input")).toHaveCSS("font-size", `${text + 4}px`);
	});
}

test("the style picker is one keyboard-accessible control that saves changes and restores the default", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.getByRole("button", { name: "Appearance", exact: true }).click();
	const group = page.getByRole("radiogroup", { name: "Interface style", exact: true });
	const standard = group.getByRole("radio", { name: "Default" });
	await expect(standard).toHaveAttribute("aria-checked", "true");
	await standard.focus();
	await page.keyboard.press("ArrowRight");
	await expect(group.getByRole("radio", { name: "Streamlined", exact: true })).toBeFocused();
	await expect(page.locator("html")).toHaveAttribute("data-interface-style", "streamlined");
	expect((await sentCommands(page)).filter((message) => message.action === "setSetting").at(-1)?.payload)
		.toEqual({ key: "interfaceStyle", value: "streamlined" });
	await standard.click();
	await expect(page.locator("html")).toHaveAttribute("data-interface-style", "default");
});

test("a live style change preserves the Agents mascot target", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, initialWorld());
	await page.evaluate((spaceId) => window.__lilo!.receive({
		event: "agentActivity", moods: {}, isolatedSpaceIds: [], clients: [], agentsSpaceIds: [spaceId], agentsProfileId: "profile-1", hiddenAgentsSpaceIds: [],
	}), SPACE_2);
	const mascot = page.locator(`[data-space-dnd-id="${SPACE_2}"] .mascot`);
	await expect(mascot).toBeVisible();
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { interfaceStyle: "streamlined" } }));
	await expect.poll(async () => Math.round((await mascot.boundingBox())!.width)).toBe(18);

});


test("the icon rail keeps compact targets with a Streamlined interface", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), sidebarRail: true, settings: { interfaceStyle: "streamlined" } }, ".sidebar-rail .rail-item[data-tab-id]");
	await expect(page.locator(".sidebar-rail .rail-item[data-tab-id]").first()).toHaveCSS("height", "30px");
});


test.describe("a narrow French settings page", () => {
	test.use({ locale: "fr-FR", viewport: { width: 600, height: 400 }, reducedMotion: "reduce" });
	test("all style choices stay inside their group", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		await page.getByRole("button", { name: "Apparence", exact: true }).click();
		const group = page.getByRole("radiogroup", { name: "Style de l’interface" });
		for (const choice of await group.getByRole("radio").all()) {
			await choice.scrollIntoViewIfNeeded();
			await expect(choice).toBeInViewport();
			const bounds = (await group.boundingBox())!;
			const box = (await choice.boundingBox())!;
			expect(box.x).toBeGreaterThanOrEqual(bounds.x);
			expect(box.x + box.width).toBeLessThanOrEqual(bounds.x + bounds.width + 0.5);
		}
	});
});


test("an open palette immediately follows a changed interface style", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await expect(page.locator(".command-bar")).toHaveCSS("width", "480px");
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { interfaceStyle: "streamlined" } }));
	await expect(page.locator(".command-bar")).toHaveCSS("width", "520px");
	await expect(page.locator(".command-bar-result").first()).toHaveCSS("min-height", "48px");
	await expect(page.locator(".command-bar-input")).toHaveCSS("font-size", "18px");
});


test("the Streamlined palette stays within a short, narrow window", async ({ page }) => {
	await page.setViewportSize({ width: 390, height: 300 });
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, { ...initialWorld(), settings: { interfaceStyle: "streamlined" } });
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").fill(":");
	const bounds = (await page.locator(".command-bar").boundingBox())!;
	expect(bounds.x).toBeGreaterThanOrEqual(0);
	expect(bounds.y).toBeGreaterThanOrEqual(0);
	expect(bounds.x + bounds.width).toBeLessThanOrEqual(390);
	expect(bounds.y + bounds.height).toBeLessThanOrEqual(300);
	await expect(page.locator(".scope-picker")).toBeInViewport();
	await expect(page.locator(".command-bar-info")).toBeInViewport();
	const results = page.locator(".command-bar-results");
	await expect.poll(() => results.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true);
	await page.locator(".command-bar-input").press("ArrowUp");
	await expect(page.locator(".command-bar-result.selected")).toBeInViewport();
});
