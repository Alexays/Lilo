import { expect, test, type Locator, type Page } from "@playwright/test";
import { bootChrome, glideTo, pressAndLift, sentCommands } from "./fakeHost";
import { deepFolderWorld, nestedFolderWorld, SPACE_1 } from "./fixtures";
import { treeItem } from "../src/stores/testFixtures";

const DROP_HOLD_SETTLE_MS = 300;

function pane(page: Page): Locator {
	return page.locator(".space-pane").first();
}

function item(id: string): string {
	return `[data-dnd-item-id="${id}"]`;
}

function folderRow(id: string): string {
	return `${item(id)} > .indented-tab-wrapper > .folder-drop-zone > .folder-header-drop .folder-row, .tab-list > ${item(id)} > .folder-drop-zone > .folder-header-drop .folder-row`;
}

function childIds(page: Page, folderId: string): Promise<(string | null)[]> {
	return pane(page)
		.locator(`[data-dnd-item-id="${folderId}"] .folder-drop-zone`)
		.first()
		.locator(":scope > .folder-contents-shell > .folder-contents-clip > .folder-contents > [data-dnd-item-id]")
		.evaluateAll((rows) => rows.map((row) => row.getAttribute("data-dnd-item-id")));
}

function rootIds(page: Page): Promise<(string | null)[]> {
	return pane(page)
		.locator(".tab-list > [data-dnd-item-id]")
		.evaluateAll((rows) => rows.map((row) => row.getAttribute("data-dnd-item-id")));
}

async function drops(page: Page): Promise<Record<string, unknown>[]> {
	return (await sentCommands(page)).filter((c) => c.action === "commitSidebarDrop").map((c) => c.payload);
}

test("a folder dropped on another folder's header goes in first", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await pressAndLift(page, folderRow("folder-archive"));
	await glideTo(page, folderRow("folder-projects"), 22);
	await page.mouse.up();

	expect((await drops(page)).at(-1)).toMatchObject({
		kind: "folder",
		id: "folder-archive",
		parentFolderId: "folder-projects",
	});
	await expect.poll(() => childIds(page, "folder-projects")).toEqual(["folder-archive", "folder-clients", "tab-beta"]);
	await page.waitForTimeout(DROP_HOLD_SETTLE_MS);
	expect(await rootIds(page)).toEqual(["folder-projects", "tab-gamma"]);
});

test("a collapsed folder takes a folder dropped on the middle of its header", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await pressAndLift(page, folderRow("folder-acme"));
	await glideTo(page, folderRow("folder-archive"), 14);
	await expect(pane(page).locator(`${item("folder-archive")} .folder-header-drop.drop-into`)).toBeVisible();
	await page.mouse.up();

	expect((await drops(page)).at(-1)).toMatchObject({ kind: "folder", id: "folder-acme", parentFolderId: "folder-archive" });
	await expect.poll(() => childIds(page, "folder-clients")).toEqual([]);
});

test("a subfolder reorders among its siblings", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await pressAndLift(page, folderRow("folder-clients"));
	// The first glide lifts Clients out, which moves tab-beta up: the second follows it.
	await glideTo(page, `${item("folder-projects")} [data-tab-id="tab-beta"]`, 18);
	await glideTo(page, `${item("folder-projects")} [data-tab-id="tab-beta"]`, 18);
	await page.mouse.up();

	expect((await drops(page)).at(-1)).toMatchObject({
		kind: "folder",
		id: "folder-clients",
		parentFolderId: "folder-projects",
		insertAfterId: "tab-beta",
	});
	await expect.poll(() => childIds(page, "folder-projects")).toEqual(["tab-beta", "folder-clients"]);
});

test("the bottom of an open subfolder last in its folder drops after it, inside the folder", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());
	const acme = `${item("folder-clients")} ${item("folder-acme")}`;

	await pressAndLift(page, `.tab-list > ${item("tab-gamma")}`);
	const box = (await pane(page).locator(acme).boundingBox())!;
	await glideTo(page, acme, box.height - 2);
	await page.mouse.up();

	expect((await drops(page)).at(-1)).toMatchObject({ id: "tab-gamma", parentFolderId: "folder-clients", insertAfterId: "folder-acme" });
	await expect.poll(() => childIds(page, "folder-clients")).toEqual(["folder-acme", "tab-gamma"]);
});

test("a subfolder dragged out to the root lands between the root rows", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await pressAndLift(page, folderRow("folder-acme"));
	await glideTo(page, `.tab-list > ${item("tab-gamma")}`, 4);
	await page.mouse.up();

	expect((await drops(page)).at(-1)).toMatchObject({ kind: "folder", id: "folder-acme", parentFolderId: null });
	await expect.poll(() => rootIds(page)).toEqual(["folder-projects", "folder-acme", "tab-gamma", "folder-archive"]);
	await expect.poll(() => childIds(page, "folder-clients")).toEqual([]);
});

test("a folder's own subtree is gone while it is dragged, so it cannot land in it", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());
	const acmeBox = (await pane(page).locator(folderRow("folder-acme")).boundingBox())!;

	await pressAndLift(page, folderRow("folder-projects"));
	await page.mouse.move(acmeBox.x + acmeBox.width / 2, acmeBox.y + 14, { steps: 6 });
	await page.waitForTimeout(80);
	await expect(pane(page).locator(item("folder-acme"))).toHaveCount(0);
	await page.mouse.up();

	const parents = (await drops(page)).map((drop) => drop.parentFolderId);
	expect(parents.filter((id) => ["folder-projects", "folder-clients", "folder-acme"].includes(id as string))).toEqual([]);
});

test("a folder that would pass five levels finds no target in the deepest folder", async ({ page }) => {
	await bootChrome(page, deepFolderWorld());
	const deepest = item("folder-level-5");

	await pressAndLift(page, folderRow("folder-loose"));
	await glideTo(page, `${deepest} [data-tab-id="tab-alpha"]`);
	await expect(pane(page).locator(`${deepest} .sidebar-dnd-placeholder`)).toHaveCount(0);
	await glideTo(page, folderRow("folder-level-5"), 22);
	await expect(pane(page).locator(".sidebar-dnd-placeholder")).toHaveCount(0);
	await page.mouse.up();

	expect(await drops(page)).toEqual([]);
	await expect.poll(() => rootIds(page)).toEqual(["folder-level-1", "tab-beta", "tab-gamma", "folder-loose"]);
});

test("a folder still drops into the fourth level, which leaves it the fifth", async ({ page }) => {
	await bootChrome(page, deepFolderWorld());

	await pressAndLift(page, folderRow("folder-loose"));
	await glideTo(page, folderRow("folder-level-4"), 22);
	await page.mouse.up();
	expect((await drops(page)).at(-1)).toMatchObject({ id: "folder-loose", parentFolderId: "folder-level-4" });
});

test("a collapsed folder held under a drag opens", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await pressAndLift(page, `.tab-list > ${item("tab-gamma")}`);
	await glideTo(page, folderRow("folder-archive"), 14);
	await expect(pane(page).locator(`${item("folder-archive")} .folder-row`)).not.toHaveClass(/collapsed/, { timeout: 2000 });
	await page.mouse.up();

	const commands = await sentCommands(page);
	expect(commands.find((c) => c.action === "setTabFolderCollapsed")?.payload).toEqual({ id: "folder-archive", collapsed: false });
	expect((await drops(page)).at(-1)).toMatchObject({ id: "tab-gamma", parentFolderId: "folder-archive" });
});

test("New Folder in a folder starts renaming the subfolder the host created", async ({ page }) => {
	const world = nestedFolderWorld();
	await bootChrome(page, world);

	// What the host sends after the folder menu's New Folder: the state, then the rename request.
	await page.evaluate(({ world, spaceId, item }) => {
		const folders = [...world.foldersBySpace![spaceId], { id: "folder-new", spaceId, name: "New Folder", color: "#d97a2b", isCollapsed: false }];
		const items = world.treeItemsBySpace[spaceId].map((entry) => entry.sortOrder >= 5 ? { ...entry, sortOrder: entry.sortOrder + 1 } : entry);
		window.__lilo!.receiveBatch([
			{
				event: "browserStateChanged",
				changedSpaceId: spaceId,
				activeTabId: "tab-alpha",
				states: [{ spaceId, activeTabId: "tab-alpha", tabs: world.tabsBySpace[spaceId], folders, treeItems: [...items, item] }],
			},
			{ event: "editTabFolder", id: "folder-new" },
		]);
	}, { world, spaceId: SPACE_1, item: treeItem("folder-new", SPACE_1, 5, "unpinned", "folder", "folder-acme") });

	const input = pane(page).locator(`${item("folder-acme")} ${item("folder-new")} .folder-title-input`);
	await expect(input).toBeFocused();
	await expect(input).toHaveValue("New Folder");
	expect(await childIds(page, "folder-acme")).toEqual(["folder-new", "tab-alpha"]);
});

test("Left closes an open folder then climbs to its parent, Right opens", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());
	const clients = pane(page).locator(folderRow("folder-clients"));

	await pane(page).locator(`${item("folder-acme")} [data-tab-id="tab-alpha"]`).focus();
	await page.keyboard.press("ArrowLeft");
	await expect(pane(page).locator(folderRow("folder-acme"))).toBeFocused();

	await clients.focus();
	await page.keyboard.press("ArrowLeft");
	await expect(clients).toHaveClass(/collapsed/);
	await expect(clients).toBeFocused();

	await page.keyboard.press("ArrowLeft");
	await expect(pane(page).locator(folderRow("folder-projects"))).toBeFocused();

	await clients.focus();
	await page.keyboard.press("ArrowRight");
	await expect(clients).not.toHaveClass(/collapsed/);
	await expect(pane(page).locator(`${item("folder-acme")} [data-tab-id="tab-alpha"]`)).toBeVisible();
});

test("Down and Up walk the shown rows, pinned to unpinned and through folders", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());
	const row = (id: string) => pane(page).locator(`[data-tab-id="${id}"]`);

	await row("tab-home").focus();
	await page.keyboard.press("ArrowDown");
	await expect(pane(page).locator(folderRow("folder-projects"))).toBeFocused();
	await page.keyboard.press("ArrowDown");
	await expect(pane(page).locator(folderRow("folder-clients"))).toBeFocused();
	await page.keyboard.press("ArrowDown");
	await page.keyboard.press("ArrowDown");
	await expect(row("tab-alpha")).toBeFocused();

	// A closed folder's rows are skipped.
	await pane(page).locator(folderRow("folder-clients")).focus();
	await page.keyboard.press("ArrowLeft");
	await expect(pane(page).locator(folderRow("folder-clients"))).toHaveClass(/collapsed/);
	await page.keyboard.press("ArrowDown");
	await expect(row("tab-beta")).toBeFocused();
	await page.keyboard.press("ArrowUp");
	await expect(pane(page).locator(folderRow("folder-clients"))).toBeFocused();

	await row("tab-gamma").focus();
	await page.keyboard.press("ArrowUp");
	await page.keyboard.press("Enter");
	await expect
		.poll(async () => (await sentCommands(page)).filter((c) => c.action === "switchTab").map((c) => c.payload.id))
		.toEqual(["tab-beta"]);
});

test("five levels fit a 200 px sidebar: each indents, titles ellipsize, nothing overflows", async ({ page }) => {
	const world = deepFolderWorld();
	world.sidebarWidth = 200;
	await bootChrome(page, world);

	const lefts: number[] = [];
	for (let level = 1; level <= 5; level++) {
		const row = pane(page).locator(folderRow(`folder-level-${level}`));
		await expect(row).toBeVisible();
		lefts.push((await row.boundingBox())!.x);
	}
	for (let level = 1; level < 5; level++) expect(lefts[level] - lefts[level - 1]).toBeCloseTo(12, 0);

	const sidebarRight = await page.locator(".sidebar").evaluate((el) => el.getBoundingClientRect().right);
	const overflow = await pane(page).evaluate((root, right) => {
		const titles = [...root.querySelectorAll<HTMLElement>(".folder-title, .tab-title")];
		const scroll = root.querySelector<HTMLElement>(".space-scroll-content")!;
		return {
			ellipsized: titles.filter((title) =>
				title.scrollWidth > title.clientWidth && getComputedStyle(title).textOverflow === "ellipsis").length,
			pastEdge: [...root.querySelectorAll<HTMLElement>(".folder-row, .tab-item")]
				.filter((row) => row.getBoundingClientRect().right > right + 0.5).length,
			scrollsSideways: scroll.scrollWidth > scroll.clientWidth,
		};
	}, sidebarRight);
	// The five folder titles and the deep tab's.
	expect(overflow.ellipsized).toBeGreaterThanOrEqual(6);
	expect(overflow.pastEdge).toBe(0);
	expect(overflow.scrollsSideways).toBe(false);
	await expect(pane(page).locator(`${item("folder-level-5")} [data-tab-id="tab-alpha"]`)).toBeVisible();
});
