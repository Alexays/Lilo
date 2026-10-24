import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

// The narrowest sidebar the native host allows (MainWindowController.sidebarWidthRange).
const MIN_SIDEBAR_WIDTH = 200;

async function openNewSpaceEditor(page: Page, sidebarWidth = MIN_SIDEBAR_WIDTH): Promise<void> {
	const world = initialWorld();
	world.sidebarWidth = sidebarWidth;
	world.profiles = [{ id: "profile-1", name: "A rather long profile name", isDefault: true, color: "#7a8cf0" }];
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "openAddSpaceEditor" }));
	await expect(page.locator(".editor-panel")).toBeVisible();
}

async function rightEdge(page: Page, selector: string): Promise<number> {
	const box = await page.locator(selector).boundingBox();
	if (!box) throw new Error(`No bounding box for ${selector}`);
	return box.x + box.width;
}

test("the new space card and the emoji popover fit the narrowest sidebar", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await openNewSpaceEditor(page);
	await page.locator(".identity-name-input").fill("A space name long enough to overflow the card");
	await page.locator(".space-emoji-btn").click();
	await expect(page.locator(".emoji-popover")).toBeVisible();

	const sidebar = await rightEdge(page, ".sidebar");
	const card = await rightEdge(page, ".preview-card");
	expect(card).toBeLessThanOrEqual(sidebar);
	expect(await rightEdge(page, ".identity-name-input")).toBeLessThanOrEqual(card);
	expect(await rightEdge(page, ".emoji-popover")).toBeLessThanOrEqual(sidebar);
});

async function openFullPicker(page: Page, sidebarWidth = MIN_SIDEBAR_WIDTH): Promise<void> {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await openNewSpaceEditor(page, sidebarWidth);
	await page.locator(".space-emoji-btn").click();
	await page.locator(".emoji-more").click();
	await expect(page.locator(".emoji-picker")).toBeVisible();
}

const search = (page: Page) => page.getByRole("searchbox", { name: "Search emoji" });
const cells = (page: Page) => page.locator(".picker-cell");
const activeCell = (page: Page) => page.locator(".picker-cell.active");

test("the ··· tile opens the full picker on its search field, its categories and their emoji", async ({ page }) => {
	await openFullPicker(page);
	await expect(search(page)).toBeFocused();
	const tabs = page.locator(".emoji-picker").getByRole("tab");
	await expect(tabs).toHaveCount(9);
	await expect(page.locator(".emoji-picker").getByRole("tab", { name: "Smileys & Emotion" })).toHaveAttribute("aria-selected", "true");
	await expect(page.locator(".picker-row.header").first()).toHaveText("Smileys & Emotion");
	await expect(cells(page).first()).toHaveText("😀");
	await expect(cells(page).first()).toHaveAttribute("aria-label", "grinning face");
	// Only the rows in view exist: the 1,900 emoji are not all in the DOM.
	expect(await cells(page).count()).toBeLessThan(120);
	expect((await sentCommands(page)).some((command) => command.action === "showEmojiPicker")).toBe(false);
});

test("the full picker fits the narrowest sidebar and draws emoji at a legible size", async ({ page }) => {
	await openFullPicker(page);
	const sidebar = (await page.locator(".sidebar").boundingBox())!;
	const picker = (await page.locator(".emoji-popover").boundingBox())!;
	expect(picker.x).toBeGreaterThanOrEqual(sidebar.x);
	expect(picker.x + picker.width).toBeLessThanOrEqual(sidebar.x + sidebar.width);
	for (const tab of await page.locator(".emoji-picker").getByRole("tab").all()) {
		const box = (await tab.boundingBox())!;
		expect(box.x + box.width).toBeLessThanOrEqual(picker.x + picker.width);
	}
	const cell = (await cells(page).first().boundingBox())!;
	expect(cell.width).toBeGreaterThanOrEqual(28);
	expect(cell.height).toBe(32);
	await expect(cells(page).first()).toHaveCSS("font-size", "22px");
});

test("searching narrows the grid by name or keyword, and says when nothing matches", async ({ page }) => {
	await openFullPicker(page);
	await search(page).fill("dog");
	await expect(cells(page).first()).toHaveText("🐶");
	await expect(page.locator(".picker-row.header")).toHaveCount(0);
	await expect(page.locator(".emoji-picker").getByRole("tab", { selected: true })).toHaveCount(0);

	// "home" is a keyword of the house, not part of its name.
	await search(page).fill("home");
	await expect(cells(page).filter({ hasText: "🏠" })).toHaveCount(1);

	await search(page).fill("zzzz");
	await expect(page.getByText("No emoji found")).toBeVisible();
});

test("a category tab scrolls the grid to its section and stays selected", async ({ page }) => {
	await openFullPicker(page);
	await search(page).fill("dog");
	await page.locator(".emoji-picker").getByRole("tab", { name: "Flags" }).click();
	await expect(search(page)).toHaveValue("");
	await expect(page.locator(".emoji-picker").getByRole("tab", { name: "Flags" })).toHaveAttribute("aria-selected", "true");
	await expect(page.locator(".picker-row.header", { hasText: "Flags" })).toBeInViewport();
	await expect(cells(page).filter({ hasText: "🏁" })).toBeInViewport();
});

test("arrows walk the grid from the search field and Return picks, as a quick pick does", async ({ page }) => {
	await openFullPicker(page);
	await page.keyboard.press("ArrowDown");
	await expect(page.getByRole("listbox", { name: "Choose emoji" })).toBeFocused();
	await expect(activeCell(page)).toHaveText("😀");
	const first = (await activeCell(page).boundingBox())!;
	await page.keyboard.press("ArrowDown");
	const below = (await activeCell(page).boundingBox())!;
	expect(below.x).toBe(first.x);
	expect(below.y).toBe(first.y + 32);
	await page.keyboard.press("ArrowUp");
	await page.keyboard.press("ArrowRight");
	await expect(activeCell(page)).toHaveText("😃");

	await search(page).fill("dog");
	await page.keyboard.press("ArrowDown");
	await page.keyboard.press("ArrowRight");
	await expect(activeCell(page)).toHaveText("🐕");
	await page.keyboard.press("Enter");
	await expect(page.locator(".space-emoji-glyph")).toHaveText("🐕");
	await expect(page.locator(".emoji-popover")).toHaveCount(0);
	await expect(page.locator(".space-emoji-btn")).toBeFocused();

	await page.locator(".identity-name-input").fill("Pets");
	await page.getByRole("button", { name: "Create Space" }).click();
	const create = (await sentCommands(page)).filter((command) => command.action === "createSpace").at(-1);
	expect(create?.payload).toMatchObject({ name: "Pets", icon: "🐕" });
});

test("Escape goes back to the quick picks, then closes the popover", async ({ page }) => {
	await openFullPicker(page);
	await page.keyboard.press("Escape");
	await expect(page.locator(".emoji-picker")).toHaveCount(0);
	await expect(page.locator(".emoji-more")).toBeFocused();
	await page.keyboard.press("Escape");
	await expect(page.locator(".emoji-popover")).toHaveCount(0);
	await expect(page.locator(".editor-panel")).toBeVisible();
});

test("a pick leads Recent, which is saved and comes back from the settings", async ({ page }) => {
	await openFullPicker(page);
	await search(page).fill("fox");
	await page.keyboard.press("Enter");
	await expect(page.locator(".space-emoji-glyph")).toHaveText("🦊");
	const saved = (await sentCommands(page)).filter((command) => command.action === "setSetting").at(-1);
	expect(saved?.payload).toEqual({ key: "emojiRecent", value: "🦊" });

	await page.evaluate(() =>
		window.__lilo!.receive({ event: "settingsLoaded", settings: { emojiRecent: "🌵 🦊" } }),
	);
	await page.locator(".space-emoji-btn").click();
	await page.locator(".emoji-more").click();
	await expect(page.locator(".emoji-picker").getByRole("tab", { name: "Recent" })).toHaveAttribute("aria-selected", "true");
	await expect(page.locator(".picker-row.header").first()).toHaveText("Recent");
	await expect(cells(page).nth(0)).toHaveText("🌵");
	await expect(cells(page).nth(1)).toHaveText("🦊");
	await expect(cells(page).nth(1)).toHaveAttribute("aria-label", "fox");
});

test("a skin tone applies to the people emoji and is saved", async ({ page }) => {
	await openFullPicker(page);
	await page.getByRole("button", { name: "Skin tone" }).click();
	await page.getByRole("radio", { name: "Medium", exact: true }).click();
	const saved = (await sentCommands(page)).filter((command) => command.action === "setSetting").at(-1);
	expect(saved?.payload).toEqual({ key: "emojiSkinTone", value: "3" });
	await search(page).fill("thumbs up");
	await expect(cells(page).first()).toHaveText("👍🏽");
	await expect(cells(page).first()).toHaveAttribute("aria-label", "thumbs up");
	await search(page).fill("dog");
	await expect(cells(page).first()).toHaveText("🐶");
});

const sidebarBackground = (page: Page) =>
	page.evaluate(() => document.documentElement.style.getPropertyValue("--sidebar-bg").trim());

const reportedBackground = async (page: Page) =>
	(await sentCommands(page)).filter((command) => command.action === "updateWindowBackground").at(-1)?.payload.color;

for (const colorScheme of ["light", "dark"] as const) {
	test(`the window frame takes the color the new space editor shows in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
		await bootChrome(page, initialWorld());
		await expect.poll(() => reportedBackground(page)).toBe(await sidebarBackground(page));
		const spaceBackground = await sidebarBackground(page);

		await page.evaluate(() => window.__lilo!.receive({ event: "openAddSpaceEditor" }));
		await page.locator(".color-swatch").nth(5).click();

		await expect.poll(() => sidebarBackground(page)).not.toBe(spaceBackground);
		await expect.poll(() => reportedBackground(page)).toBe(await sidebarBackground(page));
		// The panel paints the very color the frame around the page gets.
		await expect.poll(() => page.evaluate(() => {
			const background = (selector: string) => getComputedStyle(document.querySelector(selector)!).backgroundColor;
			return background(".editor-panel") === background(".sidebar");
		})).toBe(true);

		await page.keyboard.press("Escape");
		await expect.poll(() => sidebarBackground(page)).toBe(spaceBackground);
		await expect.poll(() => reportedBackground(page)).toBe(spaceBackground);
	});
}

test("a profile choice shows its whole description, wrapping instead of cutting it", async ({ page }) => {
	await openNewSpaceEditor(page);
	const details = page.locator(".choice-detail");
	for (const detail of await details.all()) {
		expect(await detail.evaluate((node) => node.scrollWidth <= node.clientWidth)).toBe(true);
		await expect(detail).not.toHaveCSS("text-overflow", "ellipsis");
	}
});

test("a profile in the Signed in as list wears a dot of its color, not its initial", async ({ page }) => {
	await openNewSpaceEditor(page);
	const row = page.getByRole("radio", { name: /A rather long profile name/ });
	await expect(row.locator(".choice-name")).toHaveText("A rather long profile name");
	await expect(row.locator(".choice-avatar")).toHaveText("");
	const dot = row.locator(".choice-dot");
	await expect(dot).toHaveCSS("background-color", "rgb(122, 140, 240)");
	const box = (await dot.boundingBox())!;
	expect([box.width, box.height]).toEqual([10, 10]);
});

for (const sidebarWidth of [MIN_SIDEBAR_WIDTH, 260, 320]) {
	test(`the selected New profile row and its name field stay inside the list at ${sidebarWidth} px`, async ({ page }) => {
		await openNewSpaceEditor(page, sidebarWidth);
		const row = page.getByRole("radio", { name: /New profile/ });
		await row.click();
		const input = page.locator(".new-profile-input");
		await expect(input).toBeFocused();

		const list = (await page.locator(".profile-choices").boundingBox())!;
		const sidebar = (await page.locator(".sidebar").boundingBox())!;
		expect(list.x).toBeGreaterThanOrEqual(sidebar.x);
		expect(list.x + list.width).toBeLessThanOrEqual(sidebar.x + sidebar.width);
		for (const box of [await row.boundingBox(), await row.locator(".choice-check").boundingBox(), await input.boundingBox()]) {
			expect(box!.x).toBeGreaterThanOrEqual(list.x);
			expect(box!.x + box!.width).toBeLessThanOrEqual(list.x + list.width);
		}
	});
}
