import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1, SPACE_2 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

for (const [preset, row, text, favorite, space, palette] of [
	["compact", 28, 12, 36, 24, 560], ["comfortable", 32, 13, 40, 28, 600],
	["roomy", 36, 14, 44, 32, 640], ["spacious", 40, 15, 48, 36, 680],
] as const) {
	test(`${preset} coordinates the sidebar and floating palette from saved settings`, async ({ page }) => {
		await page.emulateMedia({ reducedMotion: "reduce" });
		await bootChrome(page, { ...initialWorld(), settings: { interfaceSize: preset } });
		await expect(page.locator("html")).toHaveAttribute("data-interface-size", preset);
		await expect(page.locator('[data-tab-id="tab-alpha"]')).toHaveCSS("height", `${row}px`);
		await expect(page.locator('[data-tab-id="tab-alpha"] .tab-title')).toHaveCSS("font-size", `${text}px`);
		await expect(page.locator(".bookmark-tile").first()).toHaveCSS("height", `${favorite}px`);
		await expect(page.locator(`[data-space-dnd-id="${SPACE_1}"] .space-glyph`)).toHaveCSS("width", `${space}px`);
		await expect.poll(async () => Math.round((await page.locator(".sidebar-layout .url-trigger").boundingBox())!.height)).toBe(row);
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
		await expect(page.locator(".command-bar")).toHaveCSS("width", `${palette}px`);
		await expect(page.locator(".command-bar-result").first()).toHaveCSS("height", `${row + 8}px`);
		await expect(page.locator(".command-bar-input")).toHaveCSS("font-size", `${text + 4}px`);
		await expect(page.locator(".command-bar-chip").first()).toHaveCSS("height", `${row}px`);
		await expect(page.locator(".scope-hint").first()).toHaveCSS("height", `${22 + (text - 13) * 2}px`);
		await expect(page.locator(".command-bar-footer .keycap").first()).toHaveCSS("height", `${20 + (text - 13) * 2}px`);
	});

	test(`${preset} also sizes the docked New Tab palette`, async ({ page }) => {
		await page.emulateMedia({ reducedMotion: "reduce" });
		const world = initialWorld();
		world.settings = { interfaceSize: preset };
		world.tabsBySpace[SPACE_1].push(tab("blank", SPACE_1, { url: "", title: "" }));
		world.treeItemsBySpace[SPACE_1].push(treeItem("blank", SPACE_1, 10));
		world.activeTabBySpace[SPACE_1] = "blank";
		await bootChrome(page, world);
		await expect(page.locator(".command-bar-backdrop")).toHaveClass(/docked/);
		await expect(page.locator(".command-bar")).toHaveCSS("width", `${palette}px`);
		await expect(page.locator(".scope-hint").first()).toHaveCSS("height", `${22 + (text - 13) * 2}px`);
		await expect(page.locator(".command-bar-input")).toHaveCSS("font-size", `${text + 4}px`);
	});
}

test("the size picker is one keyboard-accessible control that saves changes and restores the default", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.getByRole("button", { name: "Appearance", exact: true }).click();
	const group = page.getByRole("radiogroup", { name: "Interface size", exact: true });
	const comfortable = group.getByRole("radio", { name: "Comfortable Default" });
	await expect(comfortable).toHaveAttribute("aria-checked", "true");
	await comfortable.focus();
	await page.keyboard.press("ArrowRight");
	await expect(group.getByRole("radio", { name: "Roomy", exact: true })).toBeFocused();
	await expect(page.locator("html")).toHaveAttribute("data-interface-size", "roomy");
	expect((await sentCommands(page)).filter((message) => message.action === "setSetting").at(-1)?.payload)
		.toEqual({ key: "interfaceSize", value: "roomy" });
	await comfortable.click();
	await expect(page.locator("html")).toHaveAttribute("data-interface-size", "comfortable");
});

test("a live size change scales the Agents mascot", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, initialWorld());
	await page.evaluate((spaceId) => window.__lilo!.receive({
		event: "agentActivity", moods: {}, isolatedSpaceIds: [], clients: [], agentsSpaceIds: [spaceId], agentsProfileId: "profile-1", hiddenAgentsSpaceIds: [],
	}), SPACE_2);
	const mascot = page.locator(`[data-space-dnd-id="${SPACE_2}"] .mascot`);
	await expect(mascot).toBeVisible();
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { interfaceSize: "spacious" } }));
	await expect.poll(async () => Math.round((await mascot.boundingBox())!.width)).toBe(22);

});


test("the icon rail keeps compact targets with a spacious interface", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), sidebarRail: true, settings: { interfaceSize: "spacious" } }, ".sidebar-rail .rail-item[data-tab-id]");
	await expect(page.locator(".sidebar-rail .rail-item[data-tab-id]").first()).toHaveCSS("height", "30px");
});


test.describe("a narrow French settings page", () => {
	test.use({ locale: "fr-FR", viewport: { width: 600, height: 400 }, reducedMotion: "reduce" });
	test("all size choices stay inside their group", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		await page.getByRole("button", { name: "Apparence", exact: true }).click();
		const group = page.getByRole("radiogroup", { name: "Taille de l’interface" });
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


test("an open palette immediately follows a changed interface size", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await expect(page.locator(".command-bar")).toHaveCSS("width", "600px");
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { interfaceSize: "spacious" } }));
	await expect(page.locator(".command-bar")).toHaveCSS("width", "680px");
	await expect(page.locator(".command-bar-chip").first()).toHaveCSS("height", "40px");
	await expect(page.locator(".command-bar-input")).toHaveCSS("font-size", "19px");
});
