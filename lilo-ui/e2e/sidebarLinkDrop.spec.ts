// Links, URL text and files dragged from other apps onto the sidebar. The host sends what the drag carries as it
// enters the chrome (linkDrag); the drop events here are the ones WebKit dispatches.
import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { folderWorld, initialWorld, SPACE_1 } from "./fixtures";

type Dragged = { urls?: string[]; text?: string };

async function offer(page: Page, dragged: Dragged): Promise<void> {
	await page.evaluate(
		({ urls, text }) => window.__lilo!.receive({ event: "linkDrag", urls, text }),
		{ urls: dragged.urls ?? [], text: dragged.text ?? "" },
	);
}

// A point at `share` of the element's height (or width), in its middle on the other axis.
async function pointIn(page: Page, selector: string, share: number, horizontal = false): Promise<{ x: number; y: number }> {
	const box = await page.locator(selector).first().boundingBox();
	if (!box) throw new Error(`No bounding box for ${selector}`);
	return horizontal
		? { x: box.x + box.width * share, y: box.y + box.height / 2 }
		: { x: box.x + box.width / 2, y: box.y + box.height * share };
}

/** Dispatches a dragover at the point, as WebKit does, and says whether the chrome accepted it. */
function dragOver(page: Page, point: { x: number; y: number }): Promise<boolean> {
	return page.evaluate(({ x, y }) => {
		const event = new DragEvent("dragover", { clientX: x, clientY: y, dataTransfer: new DataTransfer(), bubbles: true, cancelable: true });
		(document.elementFromPoint(x, y) ?? document.body).dispatchEvent(event);
		return event.defaultPrevented;
	}, point);
}

async function dropAt(page: Page, point: { x: number; y: number }): Promise<void> {
	await page.evaluate(({ x, y }) => {
		const event = new DragEvent("drop", { clientX: x, clientY: y, dataTransfer: new DataTransfer(), bubbles: true, cancelable: true });
		(document.elementFromPoint(x, y) ?? document.body).dispatchEvent(event);
	}, point);
}

async function dropped(page: Page): Promise<Record<string, unknown>[]> {
	return (await sentCommands(page)).filter((c) => c.action === "openDroppedLinks").map((c) => c.payload);
}

test("a link dropped between two tabs opens a new tab there, with a line between them while aimed", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await offer(page, { urls: ["https://example.com/a"] });

	const point = await pointIn(page, '.tab-list [data-tab-id="tab-beta"]', 0.1);
	expect(await dragOver(page, point)).toBe(true);
	// Inside the sidebar column, so it scrolls and stacks with the rows.
	const line = page.locator(".space-stack .sidebar-link-drop.line");
	await expect(line).toBeVisible();
	const lineBox = await line.boundingBox();
	const alpha = await page.locator('.tab-list [data-tab-id="tab-alpha"]').boundingBox();
	const beta = await page.locator('.tab-list [data-tab-id="tab-beta"]').boundingBox();
	expect(lineBox!.y).toBeGreaterThanOrEqual(alpha!.y + alpha!.height - 2);
	expect(lineBox!.y + lineBox!.height).toBeLessThanOrEqual(beta!.y + 2);

	await dropAt(page, point);
	await expect(line).toHaveCount(0);
	expect(await dropped(page)).toEqual([{
		urls: ["https://example.com/a"],
		section: "unpinned",
		parentFolderId: null,
		fallbackIndex: 1,
		insertBeforeId: "tab-beta",
		insertAfterId: "tab-alpha",
	}]);
});

test("a link dropped on the middle of a tab, a pin or a favorite loads in it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	for (const [selector, tabId] of [
		['.tab-list [data-tab-id="tab-gamma"]', "tab-gamma"],
		['.pinned-list [data-tab-id="tab-home"]', "tab-home"],
	] as const) {
		await offer(page, { urls: ["https://example.com/b"] });
		const point = await pointIn(page, selector, 0.5);
		expect(await dragOver(page, point)).toBe(true);
		await expect(page.locator(".sidebar-link-drop:not(.line)")).toBeVisible();
		await dropAt(page, point);
		expect((await dropped(page)).at(-1)).toEqual({ urls: ["https://example.com/b"], tabId });
	}

	await offer(page, { urls: ["https://example.com/c"] });
	const tile = await pointIn(page, ".bookmark-tile", 0.5, true);
	expect(await dragOver(page, tile)).toBe(true);
	await dropAt(page, tile);
	expect((await dropped(page)).at(-1)).toEqual({ urls: ["https://example.com/c"], tabId: "tab-wiki" });
});

test("a file opens by its file URL, and URL text as the address bar reads it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const point = await pointIn(page, '.tab-list [data-tab-id="tab-gamma"]', 0.9);

	await offer(page, { urls: ["file:///Users/someone/Notes%20Folder/page.html"] });
	expect(await dragOver(page, point)).toBe(true);
	await dropAt(page, point);
	await offer(page, { text: "example.com/path" });
	expect(await dragOver(page, point)).toBe(true);
	await dropAt(page, point);

	expect((await dropped(page)).map((payload) => [payload.urls, payload.insertAfterId])).toEqual([
		[["file:///Users/someone/Notes%20Folder/page.html"], "tab-gamma"],
		[["https://example.com/path"], "tab-gamma"],
	]);
});

test("text that is no address, or a script link, is refused with no indicator", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const point = await pointIn(page, '.tab-list [data-tab-id="tab-beta"]', 0.5);

	for (const dragged of [{ text: "some words to look up" }, { urls: ["javascript:alert(1)"] }]) {
		await offer(page, dragged);
		expect(await dragOver(page, point)).toBe(false);
		await expect(page.locator(".sidebar-link-drop")).toHaveCount(0);
		await dropAt(page, point);
	}
	expect(await dropped(page)).toEqual([]);
});

test("a link dropped on a folder opens in it, and between its tabs at that place", async ({ page }) => {
	await bootChrome(page, folderWorld());

	await offer(page, { urls: ["https://example.com/d"] });
	const header = await pointIn(page, '[role="treeitem"][aria-label="Docs"]', 0.7);
	expect(await dragOver(page, header)).toBe(true);
	await dropAt(page, header);

	await offer(page, { urls: ["https://example.com/e"] });
	const child = await pointIn(page, '.folder-contents [data-tab-id="tab-alpha"]', 0.1);
	expect(await dragOver(page, child)).toBe(true);
	await dropAt(page, child);

	await offer(page, { urls: ["https://example.com/f"] });
	const shut = await pointIn(page, '[role="treeitem"][aria-label="Shut"]', 0.6);
	expect(await dragOver(page, shut)).toBe(true);
	await dropAt(page, shut);

	expect((await dropped(page)).map(({ parentFolderId, insertBeforeId, insertAfterId }) =>
		({ parentFolderId, insertBeforeId, insertAfterId }))).toEqual([
		{ parentFolderId: "folder-docs", insertBeforeId: null, insertAfterId: "tab-alpha" },
		{ parentFolderId: "folder-docs", insertBeforeId: "tab-alpha", insertAfterId: null },
		{ parentFolderId: "folder-shut", insertBeforeId: null, insertAfterId: null },
	]);
});

test("a locked folder takes no link, and a split's pane loads one even at its edge", async ({ page }) => {
	const world = folderWorld();
	const folders = world.foldersBySpace![SPACE_1];
	folders[0] = { ...folders[0], isLocked: true };
	folders.push({
		id: "folder-split", spaceId: SPACE_1, name: "", color: "#4a90d9", isCollapsed: false, isSplit: true,
		splitLayout: { vertical: false, first: { tabId: "tab-beta" }, second: { tabId: "tab-gamma" } },
	});
	const items = world.treeItemsBySpace[SPACE_1];
	for (const item of items) {
		if (item.itemId === "tab-beta" || item.itemId === "tab-gamma") item.parentFolderId = "folder-split";
	}
	items.push({ ...items.find((item) => item.itemId === "folder-empty")!, itemId: "folder-split", sortOrder: 8 });
	await bootChrome(page, world, '.tab-list [data-tab-id="tab-gamma"]');

	await offer(page, { urls: ["https://example.com/g"] });
	const locked = await pointIn(page, '[role="treeitem"][aria-label*="Docs"]', 0.7);
	expect(await dragOver(page, locked)).toBe(true);
	await expect(page.locator(".sidebar-link-drop.line")).toBeVisible();
	await dropAt(page, locked);

	await offer(page, { urls: ["https://example.com/h"] });
	const paneEdge = await pointIn(page, '.split-row [data-tab-id="tab-gamma"]', 0.05);
	expect(await dragOver(page, paneEdge)).toBe(true);
	await dropAt(page, paneEdge);

	const [intoLocked, intoPane] = await dropped(page);
	expect(intoLocked).toMatchObject({ parentFolderId: null, insertAfterId: "folder-docs" });
	expect(intoPane).toEqual({ urls: ["https://example.com/h"], tabId: "tab-gamma" });
});

test("the sidebar leaves a drag that carries nothing to open, or has left the chrome, to the page", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const point = await pointIn(page, '.tab-list [data-tab-id="tab-beta"]', 0.5);
	expect(await dragOver(page, point)).toBe(false);

	await offer(page, { urls: ["https://example.com/i"] });
	expect(await dragOver(page, point)).toBe(true);
	await expect(page.locator(".sidebar-link-drop")).toBeVisible();
	// The host empties the offer as the drag leaves the chrome, dropped elsewhere or cancelled.
	await offer(page, {});
	await expect(page.locator(".sidebar-link-drop")).toHaveCount(0);
	expect(await dragOver(page, point)).toBe(false);
	await dropAt(page, point);
	expect(await dropped(page)).toEqual([]);
});
