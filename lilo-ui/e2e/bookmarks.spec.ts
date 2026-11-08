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

// The fixture has one favorite already; `count` is the total.
function favoritesWorld(count: number, extraTabs = 0) {
	const world = initialWorld();
	const favorites = Array.from({ length: count - 1 }, (_, index) => `tab-favorite-${index}`);
	world.tabsBySpace[SPACE_1].push(...favorites.map((id) => tab(id, SPACE_1, { isBookmarked: true })));
	world.treeItemsBySpace[SPACE_1].push(...favorites.map((id, index) => treeItem(id, SPACE_1, 10 + index, "bookmarked")));
	const tabs = Array.from({ length: extraTabs }, (_, index) => `tab-extra-${index}`);
	world.tabsBySpace[SPACE_1].push(...tabs.map((id) => tab(id, SPACE_1)));
	world.treeItemsBySpace[SPACE_1].push(...tabs.map((id, index) => treeItem(id, SPACE_1, 100 + index)));
	return world;
}

async function tilesPerRow(page: Page, count: number): Promise<number[]> {
	const tiles = page.locator(".space-pane").first().locator(".bookmark-tile");
	await expect(tiles).toHaveCount(count);
	const tops = await tiles.evaluateAll((els) => els.map((el) => Math.round(el.getBoundingClientRect().top)));
	return [...new Set(tops)].map((top) => tops.filter((other) => other === top).length);
}

test("four favorites line up two by two, as large tiles", async ({ page }) => {
	await bootChrome(page, favoritesWorld(4));
	expect(await tilesPerRow(page, 4)).toEqual([2, 2]);
	await expect(page.locator(".space-pane").first().locator(".bookmark-tile").first()).toHaveCSS("height", "48px");
});

test("five favorites take the three columns that fit, then two", async ({ page }) => {
	await bootChrome(page, favoritesWorld(5));
	expect(await tilesPerRow(page, 5)).toEqual([3, 2]);
});

test("past three rows the favorites go back to compact tiles", async ({ page }) => {
	await bootChrome(page, favoritesWorld(12));
	expect(await tilesPerRow(page, 12)).toEqual([4, 4, 4]);
	await expect(page.locator(".space-pane").first().locator(".bookmark-tile").first()).toHaveCSS("height", "40px");
});

test("favorites stay pinned above the scrolled tabs while they fit", async ({ page }) => {
	await bootChrome(page, favoritesWorld(5, 40));
	const pane = page.locator(".space-pane").first();
	const favorites = pane.locator(".favorites-section");
	await expect(favorites).toHaveClass(/pinned/);
	const before = (await favorites.boundingBox())!;

	await pane.locator(".space-scroll").evaluate((el) => el.scrollTo({ top: 400 }));
	await expect(favorites).toHaveClass(/scrolled/);
	expect((await favorites.boundingBox())!.y).toBe(before.y);
	await expect(pane.locator(".bookmark-tile").first()).toBeInViewport();
});

test("a grid too tall to pin scrolls away with the tabs, and the tab list keeps its room", async ({ page }) => {
	await bootChrome(page, favoritesWorld(60));
	const pane = page.locator(".space-pane").first();
	await expect(pane.locator(".favorites-section")).not.toHaveClass(/pinned/);
	await expect(pane.locator(".space-scroll")).toHaveCount(1);

	await pane.locator(".space-scroll").evaluate((el) => el.scrollTo({ top: el.scrollHeight }));
	await expect(pane.locator('.tab-list [data-tab-id="tab-gamma"]')).toBeInViewport();
	await expect(pane.locator(".bookmark-tile").first()).not.toBeInViewport();
});
