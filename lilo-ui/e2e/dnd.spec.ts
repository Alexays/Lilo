// Assertions run on the DOM after the host echoed browserStateChanged; the re-check after the drop-settle hold
// proves the order comes from the store, not the transient hold.
import { expect, test, type Locator, type Page } from "@playwright/test";
import { bootChrome, centerOf, dragFromTo, glideTo, pressAndLift, sentCommands, settleDrop } from "./fakeHost";
import { folderWorld, initialWorld, SPACE_1, SPACE_2 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

const ROW_MOTION_MS = 300;

test.beforeEach(({ page }) => page.clock.install());

function pane(page: Page, index: number): Locator {
	return page.locator(".space-pane").nth(index);
}

function unpinnedIds(paneLocator: Locator): Promise<(string | null)[]> {
	return paneLocator
		.locator(".tab-list [data-tab-id]")
		.evaluateAll((rows) => rows.map((row) => row.getAttribute("data-tab-id")));
}

test("dropping on a tab's center splits beside that tab, even when it is inactive", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const target = '.tab-list [data-tab-id="tab-beta"]';
	await pressAndLift(page, '.tab-list [data-tab-id="tab-gamma"]');
	await glideTo(page, target);
	await expect(pane(page, 0).locator(target).getByText("Split view")).toBeVisible();
	await page.mouse.up();

	const commands = await sentCommands(page);
	expect(commands.filter((c) => c.action === "splitTab")).toEqual([
		{ action: "splitTab", payload: { tabId: "tab-gamma", side: "right", targetTabId: "tab-beta" } },
	]);
	expect(commands.some((c) => c.action === "commitSidebarDrop")).toBe(false);
});

test("reorder within the unpinned list changes the DOM order", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());
	const activePane = pane(page, 0);

	// Starting the drag reveals the empty pinned drop zone and shifts the list: aim at beta's live box.
	await pressAndLift(page, '.tab-list [data-tab-id="tab-alpha"]');
	await page.waitForTimeout(250);
	await glideTo(page, '.tab-list [data-tab-id="tab-beta"]', 21);
	await page.mouse.up();

	await expect
		.poll(() => unpinnedIds(activePane))
		.toEqual(["tab-beta", "tab-alpha", "tab-gamma"]);
	const commands = await sentCommands(page);
	const drop = commands.find((c) => c.action === "commitSidebarDrop");
	expect(drop?.payload).toMatchObject({ type: "insert", id: "tab-alpha" });

	await settleDrop(page);
	expect(await unpinnedIds(activePane)).toEqual([
		"tab-beta",
		"tab-alpha",
		"tab-gamma",
	]);
});

test("dragging an unpinned row into the pinned list pins it", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());
	const activePane = pane(page, 0);

	await pressAndLift(page, '.tab-list [data-tab-id="tab-gamma"]');
	await glideTo(page, '.pinned-list [data-tab-id="tab-home"]', 5);
	await page.mouse.up();

	await expect(
		activePane.locator('.pinned-list [data-tab-id="tab-gamma"]'),
	).toBeVisible();
	await expect(activePane.locator(".pinned-list [data-tab-id]")).toHaveCount(2);
	await expect(activePane.locator(".tab-list [data-tab-id]")).toHaveCount(2);

	await settleDrop(page);
	await expect(
		activePane.locator('.pinned-list [data-tab-id="tab-gamma"]'),
	).toBeVisible();
});

test("dragging an unpinned row into the bookmarks grid bookmarks it", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());
	const activePane = pane(page, 0);

	const from = await centerOf(page, '.tab-list [data-tab-id="tab-gamma"]');
	const to = await centerOf(page, ".bookmarked-list");
	await dragFromTo(page, from, to);

	await expect(activePane.locator(".bookmarked-list .bookmark-tile")).toHaveCount(2);
	await expect(
		activePane.locator('.bookmarked-list [aria-label="Gamma News"]'),
	).toBeVisible();
	await expect(activePane.locator(".tab-list [data-tab-id]")).toHaveCount(2);

	await settleDrop(page);
	await expect(activePane.locator(".bookmarked-list .bookmark-tile")).toHaveCount(2);
});

test("a row held over the favorites grid leaves its columns alone until the drop", async ({ page }) => {
	const world = initialWorld();
	const favorites = ["tab-fav-1", "tab-fav-2", "tab-fav-3"];
	world.tabsBySpace[SPACE_1].push(...favorites.map((id) => tab(id, SPACE_1, { isBookmarked: true })));
	world.treeItemsBySpace[SPACE_1].push(...favorites.map((id, index) => treeItem(id, SPACE_1, 10 + index, "bookmarked")));
	await bootChrome(page, world);
	const grid = pane(page, 0).locator(".bookmarked-list");
	const columns = () => grid.evaluate((el) => getComputedStyle(el).gridTemplateColumns.split(" ").length);
	expect(await columns()).toBe(2);

	await pressAndLift(page, '.tab-list [data-tab-id="tab-gamma"]');
	await glideTo(page, ".bookmarked-list");
	await expect(grid.locator(".bookmark-placeholder")).toHaveCount(1);
	expect(await columns()).toBe(2);
	await page.mouse.up();

	await settleDrop(page);
	await expect(grid.locator(".bookmark-tile")).toHaveCount(5);
	expect(await columns()).toBe(3);
});

test("a row dragged into the pinned favorites while the list is scrolled bookmarks it", async ({ page }) => {
	const world = initialWorld();
	const tabs = Array.from({ length: 40 }, (_, index) => `tab-extra-${index}`);
	world.tabsBySpace[SPACE_1].push(...tabs.map((id) => tab(id, SPACE_1)));
	world.treeItemsBySpace[SPACE_1].push(...tabs.map((id, index) => treeItem(id, SPACE_1, 100 + index)));
	await bootChrome(page, world);
	const activePane = pane(page, 0);
	await expect(activePane.locator(".favorites-section")).toHaveClass(/pinned/);
	await activePane.locator(".space-scroll").evaluate((el) => el.scrollTo({ top: 600 }));

	const row = '.tab-list [data-tab-id="tab-extra-20"]';
	await expect(activePane.locator(row)).toBeInViewport();
	await pressAndLift(page, row);
	await glideTo(page, ".bookmarked-list");
	// The list scrolls under the held tile; the pinned grid stays under the pointer.
	await activePane.locator(".space-scroll").evaluate((el) => el.scrollBy({ top: 200 }));
	await glideTo(page, ".bookmarked-list");
	await page.mouse.up();

	await expect(activePane.locator('.bookmarked-list [aria-label="tab-extra-20"]')).toHaveCount(1);
	await settleDrop(page);
	await expect(activePane.locator(".bookmarked-list .bookmark-tile")).toHaveCount(2);
});

test("dropping a tab onto a space in the bottom bar moves it there", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());
	const sourcePane = pane(page, 0);
	const targetPane = pane(page, 1);

	const from = await centerOf(page, '.tab-list [data-tab-id="tab-beta"]');
	const to = await centerOf(page, `[data-space-dnd-id="${SPACE_2}"]`);
	await dragFromTo(page, from, to);

	const commands = await sentCommands(page);
	expect(
		commands.find((c) => c.action === "moveTabToSpace")?.payload,
	).toMatchObject({ tabId: "tab-beta", spaceId: SPACE_2 });
	expect(commands.some((c) => c.action === "commitSidebarDrop")).toBe(false);
	await expect(sourcePane.locator(".tab-list [data-tab-id]")).toHaveCount(2);
	await expect(
		sourcePane.locator('.tab-list [data-tab-id="tab-beta"]'),
	).toHaveCount(0);

	// The tab can only show up in space 2 through the echoed state: switch and look.
	await page.locator(`[data-space-dnd-id="${SPACE_2}"] .space-icon-btn`).click();
	await expect
		.poll(() => unpinnedIds(targetPane))
		.toEqual(["tab-zeta", "tab-beta"]);
});

function rootIds(paneLocator: Locator): Promise<(string | null)[]> {
	return paneLocator
		.locator(".tab-list > [data-dnd-item-id]")
		.evaluateAll((rows) => rows.map((row) => row.getAttribute("data-dnd-item-id")));
}

function lastDrop(page: Page): Promise<Record<string, unknown> | undefined> {
	return sentCommands(page).then((commands) =>
		commands.findLast((c) => c.action === "commitSidebarDrop")?.payload
	);
}

function rowTops(paneLocator: Locator): Promise<Record<string, number>> {
	return paneLocator.locator("[data-dnd-item-id]").evaluateAll((rows) => Object.fromEntries(rows.map((row) => [
		row.getAttribute("data-dnd-item-id")!.replace("dnd-shadow:", ""),
		Math.round(row.getBoundingClientRect().top),
	])));
}

test("the rows stay where the drag showed them once the drop lands", async ({
	page,
}) => {
	await bootChrome(page, folderWorld());
	const activePane = pane(page, 0);

	await pressAndLift(page, '.tab-list [data-tab-id="tab-gamma"]');
	await glideTo(page, '.tab-list > [data-dnd-item-id="tab-beta"]', 5);
	await page.waitForTimeout(ROW_MOTION_MS);
	const during = await rowTops(activePane);
	await page.mouse.up();
	await expect.poll(() => rootIds(activePane)).toEqual(["folder-docs", "tab-gamma", "tab-beta", "folder-empty", "folder-shut"]);
	await settleDrop(page);

	expect(await rowTops(activePane)).toEqual(during);
});

test("a row dragged away and back to the middle of its starting row drops where it was", async ({
	page,
}) => {
	await bootChrome(page, folderWorld());
	const activePane = pane(page, 0);
	const home = (await activePane.locator('.tab-list > [data-dnd-item-id="tab-gamma"]').boundingBox())!;

	await pressAndLift(page, '.tab-list [data-tab-id="tab-gamma"]');
	await glideTo(page, '.tab-list > [data-dnd-item-id="tab-beta"]', 5);
	await expect.poll(() => rootIds(activePane)).toEqual(["folder-docs", "dnd-shadow:tab-gamma", "tab-beta", "folder-empty", "folder-shut"]);
	await page.mouse.move(home.x + home.width / 2, home.y + home.height / 2 + 2, { steps: 6 });
	await page.waitForTimeout(ROW_MOTION_MS);
	await page.mouse.up();

	await expect.poll(() => rootIds(activePane)).toEqual(["folder-docs", "tab-beta", "tab-gamma", "folder-empty", "folder-shut"]);
});

test("a folder's last tab dragged out leaves the folder as it will look after the drop", async ({
	page,
}) => {
	await bootChrome(page, folderWorld());
	const activePane = pane(page, 0);

	await pressAndLift(page, '[data-dnd-item-id="folder-docs"] [data-tab-id="tab-alpha"]');
	await glideTo(page, '.tab-list > [data-dnd-item-id="folder-docs"]', 3);
	await page.waitForTimeout(ROW_MOTION_MS);
	const during = await rowTops(activePane);
	await page.mouse.up();
	await expect.poll(() => rootIds(activePane)).toEqual(["tab-alpha", "folder-docs", "tab-beta", "tab-gamma", "folder-empty", "folder-shut"]);
	await settleDrop(page);

	expect(await rowTops(activePane)).toEqual(during);
});

test("a tab dropped on an empty folder's placeholder lands inside it", async ({
	page,
}) => {
	await bootChrome(page, folderWorld());
	const activePane = pane(page, 0);
	const folder = '[data-dnd-item-id="folder-empty"]';

	await pressAndLift(page, '.tab-list [data-tab-id="tab-beta"]');
	// The first glide lifts tab-beta out, which moves the folder up: the second follows it.
	await glideTo(page, folder, 24);
	await glideTo(page, folder, 24);
	await glideTo(page, `${folder} .sidebar-dnd-placeholder.folder`);
	await page.mouse.up();

	expect(await lastDrop(page)).toMatchObject({
		id: "tab-beta",
		parentFolderId: "folder-empty",
	});
	await expect(activePane.locator(`${folder} [data-tab-id="tab-beta"]`)).toBeVisible();
	await settleDrop(page);
	await expect(activePane.locator(`${folder} [data-tab-id="tab-beta"]`)).toBeVisible();
});

test("a folder child dragged out below its folder lands between the root rows", async ({
	page,
}) => {
	await bootChrome(page, folderWorld());
	const activePane = pane(page, 0);

	await pressAndLift(page, '[data-dnd-item-id="folder-docs"] [data-tab-id="tab-alpha"]');
	await glideTo(page, '.tab-list > [data-dnd-item-id="tab-beta"]');
	await glideTo(page, '.tab-list > [data-dnd-item-id="tab-gamma"]', 6);
	await page.mouse.up();

	expect(await lastDrop(page)).toMatchObject({ id: "tab-alpha", parentFolderId: null });
	await expect
		.poll(() => rootIds(activePane))
		.toEqual(["folder-docs", "tab-beta", "tab-alpha", "tab-gamma", "folder-empty", "folder-shut"]);
	await settleDrop(page);
	expect(await rootIds(activePane)).toEqual([
		"folder-docs",
		"tab-beta",
		"tab-alpha",
		"tab-gamma",
		"folder-empty",
		"folder-shut",
	]);
});

test("a tab dropped on a collapsed folder's header goes into the folder", async ({
	page,
}) => {
	await bootChrome(page, folderWorld());
	const activePane = pane(page, 0);
	const folder = '[data-dnd-item-id="folder-shut"]';

	await pressAndLift(page, '.tab-list [data-tab-id="tab-gamma"]');
	await glideTo(page, folder, 15);
	await expect(activePane.locator(`${folder} .folder-header-drop.drop-into`)).toBeVisible();
	await page.mouse.up();

	expect(await lastDrop(page)).toMatchObject({
		id: "tab-gamma",
		parentFolderId: "folder-shut",
	});
	await expect
		.poll(() => rootIds(activePane))
		.toEqual(["folder-docs", "tab-beta", "folder-empty", "folder-shut"]);
});

test("a space icon released over the sidebar leaves the space bar as it was", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await pressAndLift(page, `[data-space-dnd-id="${SPACE_1}"]`);
	await glideTo(page, `[data-space-dnd-id="${SPACE_2}"]`);
	await glideTo(page, '.tab-list [data-tab-id="tab-beta"]');
	await page.mouse.up();

	await expect(page.locator(".space-dnd-placeholder")).toHaveCount(0);
	const commands = await sentCommands(page);
	expect(commands.some((c) => c.action === "commitSidebarDrop")).toBe(false);
	expect(commands.some((c) => c.action === "moveSpace")).toBe(false);
});

test("without pins the divider line only shows while dragging", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());
	await expect(pane(page, 0).locator(".pinned-tab-divider")).not.toHaveClass(/hidden-line/);

	await page.locator(`[data-space-dnd-id="${SPACE_2}"] .space-icon-btn`).click();
	const divider = pane(page, 1).locator(".pinned-tab-divider");
	await expect(divider).toHaveClass(/hidden-line/);

	await pressAndLift(page, '.space-pane >> nth=1 >> .tab-list [data-tab-id="tab-zeta"]');
	await expect(divider).not.toHaveClass(/hidden-line/);
	await page.mouse.up();
	await expect(divider).toHaveClass(/hidden-line/);
});

test("a drag in a long list mounts every row of its own space only, then drops in place", async ({ page }) => {
	const world = initialWorld();
	for (const [space, prefix] of [[SPACE_1, "a"], [SPACE_2, "b"]] as const) {
		world.tabsBySpace[space] = Array.from({ length: 120 }, (_, i) => tab(`${prefix}-${i}`, space, { title: `Tab ${prefix} ${i}` }));
		world.treeItemsBySpace[space] = Array.from({ length: 120 }, (_, i) => treeItem(`${prefix}-${i}`, space, i));
		world.activeTabBySpace[space] = `${prefix}-0`;
	}
	await bootChrome(page, world);
	await page.evaluate((state) => {
		window.__lilo!.receive({ event: "browserStateChanged", changedSpaceId: state.spaceId, activeTabId: state.activeTabId, states: [state] });
	}, { spaceId: SPACE_2, activeTabId: "b-0", tabs: world.tabsBySpace[SPACE_2], folders: [], treeItems: world.treeItemsBySpace[SPACE_2] });
	const active = page.locator(".space-pane", { has: page.locator('[data-tab-id="a-0"]') });
	const neighbour = page.locator(".space-pane", { has: page.locator('[data-tab-id="b-0"]') });
	await expect(active.locator(".virtual-spacer")).not.toHaveCount(0);
	await expect(neighbour.locator(".virtual-spacer")).not.toHaveCount(0);

	await pressAndLift(page, '[data-dnd-item-id="a-1"]');
	await page.waitForTimeout(250);
	await glideTo(page, '[data-dnd-item-id="a-4"]', 21);
	await expect(active.locator('[data-tab-id="a-119"]')).toHaveCount(1);
	await expect(active.locator(".virtual-spacer")).toHaveCount(0);
	await expect(neighbour.locator(".virtual-spacer")).not.toHaveCount(0);
	await page.mouse.up();

	const drop = (await sentCommands(page)).find((c) => c.action === "commitSidebarDrop");
	expect(drop?.payload).toMatchObject({ id: "a-1", insertAfterId: "a-4", insertBeforeId: "a-5" });
});
