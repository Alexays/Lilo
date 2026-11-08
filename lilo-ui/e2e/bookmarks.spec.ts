import { expect, test, type Page } from "@playwright/test";
import { tab, treeItem } from "../src/stores/testFixtures";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

test("a favorite tile spans the rows' width, with their edges and radius and no border", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const pane = page.locator(".space-pane").first();
	const tile = pane.locator(".bookmark-tile").first();
	const row = pane.locator('.tab-list [data-tab-id="tab-beta"]');

	const tileBox = (await tile.boundingBox())!;
	const rowBox = (await row.boundingBox())!;
	expect(tileBox.x).toBeCloseTo(rowBox.x, 0);
	expect(tileBox.width).toBeCloseTo(rowBox.width, 0);
	await expect(tile).toHaveCSS("border-top-width", "0px");
	expect(await tile.evaluate((el) => getComputedStyle(el).borderRadius)).toBe(await row.evaluate((el) => getComputedStyle(el).borderRadius));
});

test("Edit from the menu opens a bookmark's editor under the tiles, and Return saves its name and address", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const pane = page.locator(".space-pane").first();

	await page.evaluate(() => window.__lilo!.receive({ event: "beginTabEdit", id: "tab-wiki", homeURL: "https://example.com/tab-wiki" }));
	const editor = pane.locator(".bookmark-editor .saved-tab-editor");
	const name = editor.getByRole("textbox", { name: "Tab name" });
	await expect(name).toBeFocused();
	await expect(name).toHaveValue("Marked Wiki");
	await expect(pane.locator(".bookmark-tile.editing")).toHaveAttribute("aria-label", "Marked Wiki");

	await name.fill("Wiki");
	await editor.getByRole("textbox", { name: "Address" }).fill("wiki.example.com/start");
	await page.keyboard.press("Enter");

	await expect(editor).toHaveCount(0);
	await expect(pane.locator(".bookmark-tile").first()).toHaveAttribute("aria-label", "Wiki");
	const edits = (await sentCommands(page)).filter((command) => command.action === "renameTab" || command.action === "setTabHomeURL");
	expect(edits.map((command) => [command.action, command.payload])).toEqual([
		["renameTab", { id: "tab-wiki", title: "Wiki" }],
		["setTabHomeURL", { id: "tab-wiki", url: "https://wiki.example.com/start" }],
	]);
});

test("a favorite tile moves with Option-arrows and opens its menu with Shift-F10", async ({ page }) => {
	const world = initialWorld();
	Object.assign(world.tabsBySpace[SPACE_1].find((tab) => tab.id === "tab-home")!, { isPinned: false, isBookmarked: true });
	world.treeItemsBySpace[SPACE_1][1] = treeItem("tab-home", SPACE_1, 1, "bookmarked");
	await bootChrome(page, world);
	const wiki = page.locator(".space-pane").first().getByRole("button", { name: "Marked Wiki" });

	await wiki.focus();
	await page.keyboard.press("Alt+ArrowRight");
	const drops = (await sentCommands(page)).filter((command) => command.action === "commitSidebarDrop");
	expect(drops.at(-1)?.payload).toMatchObject({
		type: "insert", kind: "tab", id: "tab-wiki", section: "bookmarked", parentFolderId: null, insertAfterId: "tab-home", insertBeforeId: null,
	});
	await expect(page.locator(".live-announcer")).toHaveText("Moved to position 2 of 2");

	await wiki.focus();
	await page.keyboard.press("Shift+F10");
	expect((await sentCommands(page)).filter((command) => command.action === "showTabContextMenu").at(-1)?.payload).toMatchObject({ id: "tab-wiki" });
});

function favoritesWorld(settings?: Record<string, string>) {
	const world = initialWorld();
	const extra = ["one", "two", "three", "four", "five"].map((name) => `tab-${name}`);
	world.tabsBySpace[SPACE_1].push(...extra.map((id) => tab(id, SPACE_1, { isBookmarked: true })));
	world.treeItemsBySpace[SPACE_1].push(...extra.map((id, index) => treeItem(id, SPACE_1, 10 + index, "bookmarked")));
	world.settings = settings;
	return world;
}

async function favoriteRowTops(page: Page): Promise<number[]> {
	const tiles = page.locator(".space-pane").first().locator(".bookmark-tile");
	await expect(tiles).toHaveCount(6);
	return tiles.evaluateAll((els) => els.map((el) => Math.round(el.getBoundingClientRect().top)));
}

test("favorites line up two a row by default, and wrap the rest", async ({ page }) => {
	await bootChrome(page, favoritesWorld());
	const tops = await favoriteRowTops(page);
	expect(new Set(tops).size).toBe(3);
	expect(tops[1]).toBe(tops[0]);
	expect(tops[2]).toBeGreaterThan(tops[0]);
});

test("the Favorites per row setting lines up four a row", async ({ page }) => {
	await bootChrome(page, favoritesWorld({ favoritesPerRow: "4" }));
	const tops = await favoriteRowTops(page);
	expect(tops.slice(0, 4).every((top) => top === tops[0])).toBe(true);
	expect(tops[4]).toBeGreaterThan(tops[0]);
	expect(tops[5]).toBe(tops[4]);
});

test("many favorites scroll on their own and leave the tab list its room", async ({ page }) => {
	const world = initialWorld();
	const extra = Array.from({ length: 24 }, (_, index) => `tab-favorite-${index}`);
	world.tabsBySpace[SPACE_1].push(...extra.map((id) => tab(id, SPACE_1, { isBookmarked: true })));
	world.treeItemsBySpace[SPACE_1].push(...extra.map((id, index) => treeItem(id, SPACE_1, 10 + index, "bookmarked")));
	await bootChrome(page, world);
	const pane = page.locator(".space-pane").first();

	const list = (await pane.locator(".bookmarked-list").boundingBox())!;
	expect(list.height).toBeLessThanOrEqual(page.viewportSize()!.height * 0.4 + 1);
	await expect(pane.locator('.tab-list [data-tab-id="tab-gamma"]')).toBeInViewport();
});
