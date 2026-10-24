import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, nestedFolderWorld } from "./fixtures";

const tree = (page: Page) => page.getByRole("tree", { name: "Open tabs" });
const row = (page: Page, name: string | RegExp) => tree(page).getByRole("treeitem", { name });

async function drops(page: Page): Promise<Record<string, unknown>[]> {
	return (await sentCommands(page)).filter((c) => c.action === "commitSidebarDrop").map((c) => c.payload as Record<string, unknown>);
}

function rootIds(page: Page): Promise<(string | null)[]> {
	return page.locator(".space-pane").first().locator(".tab-list > [data-dnd-item-id]")
		.evaluateAll((rows) => rows.map((el) => el.getAttribute("data-dnd-item-id")));
}

test("the tab list is a tree whose rows carry their level, open state and selection", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await expect(page.getByRole("tree", { name: "Pinned tabs" })).toBeVisible();
	await expect(row(page, "Projects")).toHaveAttribute("aria-level", "1");
	await expect(row(page, "Projects")).toHaveAttribute("aria-expanded", "true");
	await expect(row(page, "Clients")).toHaveAttribute("aria-level", "2");
	await expect(row(page, "Acme")).toHaveAttribute("aria-level", "3");
	await expect(row(page, /^Alpha Docs/)).toHaveAttribute("aria-level", "4");
	await expect(row(page, /^Alpha Docs/)).toHaveAttribute("aria-selected", "true");
	await expect(row(page, /^Beta Mail/)).toHaveAttribute("aria-selected", "false");
	await expect(row(page, "Archive")).toHaveAttribute("aria-expanded", "false");
	await expect(tree(page).getByRole("group").first()).toBeAttached();
});

test("the tree is a single Tab stop on the active tab", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await expect(tree(page).locator("[role=treeitem][tabindex='0']")).toHaveCount(1);
	await expect(row(page, /^Alpha Docs/)).toHaveAttribute("tabindex", "0");
});

test("arrow keys walk the visible rows and enter or leave folders", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await row(page, "Projects").focus();
	await page.keyboard.press("ArrowRight");
	await expect(row(page, "Clients")).toBeFocused();
	await page.keyboard.press("ArrowDown");
	await expect(row(page, "Acme")).toBeFocused();
	await page.keyboard.press("ArrowLeft");
	await expect(row(page, "Acme")).toHaveAttribute("aria-expanded", "false");
	await page.keyboard.press("ArrowLeft");
	await expect(row(page, "Clients")).toBeFocused();
	await page.keyboard.press("End");
	await expect(row(page, "Archive")).toBeFocused();
	// Home and Up reach past the open tabs into the pinned ones: the Space is one list.
	const pinnedHome = page.getByRole("tree", { name: "Pinned tabs" }).getByRole("treeitem", { name: /^Pinned Home/ });
	await page.keyboard.press("Home");
	await expect(pinnedHome).toBeFocused();
	await page.keyboard.press("ArrowUp");
	await expect(pinnedHome).toBeFocused();
	await page.keyboard.press("ArrowDown");
	await expect(row(page, "Projects")).toBeFocused();
});

test("Option-Down moves the focused tab below its sibling and keeps it focused", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await row(page, /^Alpha Docs/).focus();
	await page.keyboard.press("Alt+ArrowDown");

	expect((await drops(page)).at(-1)).toMatchObject({
		type: "insert", kind: "tab", id: "tab-alpha", section: "unpinned", parentFolderId: null,
		insertAfterId: "tab-beta", insertBeforeId: "tab-gamma",
	});
	await expect.poll(() => rootIds(page)).toEqual(["tab-beta", "tab-alpha", "tab-gamma"]);
	await expect(row(page, /^Alpha Docs/)).toBeFocused();

	await page.keyboard.press("Alt+ArrowUp");
	await expect.poll(() => rootIds(page)).toEqual(["tab-alpha", "tab-beta", "tab-gamma"]);
});

test("Option-Right moves a tab into the folder above, Option-Left takes it back out", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await row(page, /^Gamma News/).focus();
	await page.keyboard.press("Alt+ArrowRight");
	expect((await drops(page)).at(-1)).toMatchObject({
		id: "tab-gamma", parentFolderId: "folder-projects", insertAfterId: "tab-beta", insertBeforeId: null,
	});
	// The row lands in its new place while the old one plays its exit transition.
	const gammaAt = (level: number) => tree(page).locator(`[role=treeitem][data-tab-id="tab-gamma"][aria-level="${level}"]`);
	await expect(gammaAt(2)).toBeFocused();
	await expect(gammaAt(1)).toHaveCount(0);

	await page.keyboard.press("Alt+ArrowLeft");
	expect((await drops(page)).at(-1)).toMatchObject({
		id: "tab-gamma", parentFolderId: null, insertAfterId: "folder-projects", insertBeforeId: "folder-archive",
	});
	await expect(gammaAt(1)).toBeFocused();
	await expect(gammaAt(2)).toHaveCount(0);
});

test("the row a move leaves behind is inert while it plays its exit", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());
	await row(page, /^Gamma News/).focus();
	// Every frame of the move: the leaving copy is never reachable beside the row that replaces it.
	const frames = page.evaluate(() => new Promise<{ copies: number; reachable: number }>((resolve) => {
		let copies = 0, reachable = 0, frame = 0;
		const sample = () => {
			const rows = Array.from(document.querySelectorAll('[role=treeitem][data-tab-id="tab-gamma"]'));
			copies = Math.max(copies, rows.length);
			reachable = Math.max(reachable, rows.filter((el) => !el.closest("[inert]")).length);
			if (++frame < 40) requestAnimationFrame(sample);
			else resolve({ copies, reachable });
		};
		requestAnimationFrame(sample);
	}));
	await page.keyboard.press("Alt+ArrowRight");

	expect(await frames).toEqual({ copies: 2, reachable: 1 });
});

test("Shift-F10 opens the focused row's context menu", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await row(page, /^Beta Mail/).focus();
	await page.keyboard.press("Shift+F10");

	expect((await sentCommands(page)).filter((c) => c.action === "showTabContextMenu").at(-1)?.payload).toMatchObject({ id: "tab-beta" });
});
