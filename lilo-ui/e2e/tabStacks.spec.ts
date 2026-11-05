import { expect, test, type Page } from "@playwright/test";
import { tab, treeItem } from "../src/stores/testFixtures";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

// Alpha (active), Beta and Gamma on their own sites, three Acme Docs pages, then two terminals.
function stackWorld(settings: Record<string, string>) {
	const world = initialWorld();
	world.settings = settings;
	const tabs = world.tabsBySpace[SPACE_1];
	for (const entry of tabs) entry.url = `https://${entry.id}.example.org/`;
	const docs = ["Intro", "Setup", "API"].map((page) =>
		tab(`tab-docs-${page.toLowerCase()}`, SPACE_1, { title: `${page} · Acme Docs`, url: `https://docs.example.com/${page}` }),
	);
	const terminals = ["one", "two"].map((name) => tab(`tab-term-${name}`, SPACE_1, { title: `~/${name}`, url: "", kind: "terminal" }));
	tabs.push(...docs, ...terminals);
	const items = world.treeItemsBySpace[SPACE_1];
	for (const entry of [...docs, ...terminals]) items.push(treeItem(entry.id, SPACE_1, items.length));
	return world;
}

const row = (page: Page, id: string) => page.locator(`.tab-list [data-tab-id="${id}"]`);

test("three pages of a site stack under one closed row named after them", async ({ page }) => {
	await bootChrome(page, stackWorld({ sidebarStackTabs: "true" }));

	const stack = page.getByRole("treeitem", { name: "Acme Docs, 3 tabs" });
	await expect(stack).toHaveAttribute("aria-expanded", "false");
	await expect(row(page, "tab-docs-intro")).toHaveCount(0);

	await stack.click();
	await expect(stack).toHaveAttribute("aria-expanded", "true");
	await expect(row(page, "tab-docs-intro")).toContainText("Intro");
	await expect(row(page, "tab-docs-intro")).not.toContainText("Acme Docs");
	await expect(row(page, "tab-docs-setup")).toBeVisible();
});

test("a closed stack wears its active page as its face, and opening it gives the page its row back", async ({ page }) => {
	const world = stackWorld({ sidebarStackTabs: "true" });
	world.activeTabBySpace[SPACE_1] = "tab-docs-setup";
	await bootChrome(page, world);

	const face = page.getByRole("treeitem", { name: "Setup · Acme Docs, 3 tabs" });
	await expect(face).toHaveAttribute("aria-selected", "true");
	await expect(face.getByRole("button", { name: "Close Stack" })).toHaveCount(0);
	await expect(row(page, "tab-docs-setup")).toHaveCount(0);

	await face.click();
	await expect(page.getByRole("treeitem", { name: "Acme Docs, 3 tabs" })).toHaveAttribute("aria-expanded", "true");
	await expect(row(page, "tab-docs-setup")).toBeVisible();
});

test("the stack's close button closes its pages at once", async ({ page }) => {
	await bootChrome(page, stackWorld({ sidebarStackTabs: "true" }));

	const stack = page.getByRole("treeitem", { name: "Acme Docs, 3 tabs" });
	await stack.hover();
	await stack.getByRole("button", { name: "Close Stack" }).click();

	await expect(stack).toHaveAttribute("aria-expanded", "false");
	const close = (await sentCommands(page)).find((command) => command.action === "closeTabs");
	expect(close?.payload.ids).toEqual(["tab-docs-intro", "tab-docs-setup", "tab-docs-api"]);
});

test("grouped by type, terminals sit in a tray above the web that folds away", async ({ page }) => {
	await bootChrome(page, stackWorld({ sidebarGroupByType: "true" }));

	const tray = page.getByRole("treeitem", { name: "Terminals" });
	const trayBox = await tray.boundingBox();
	const alphaBox = await row(page, "tab-alpha").boundingBox();
	expect(trayBox!.y).toBeLessThan(alphaBox!.y);
	await expect(row(page, "tab-term-one")).toBeVisible();
	// No stacks while they are off: the Acme Docs pages keep their rows.
	await expect(row(page, "tab-docs-intro")).toBeVisible();

	await tray.click();
	await expect(tray).toHaveAttribute("aria-expanded", "false");
	await expect(row(page, "tab-term-one")).toHaveCount(0);
	await expect(tray).toContainText("2");
});

test("a closed stack holding every open tab still shows", async ({ page }) => {
	const world = stackWorld({ sidebarStackTabs: "true" });
	const kept = (id: string) => !["tab-alpha", "tab-beta", "tab-gamma", "tab-term-one", "tab-term-two"].includes(id);
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].filter((entry) => kept(entry.id));
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].filter((item) => kept(item.itemId));
	world.activeTabBySpace[SPACE_1] = "tab-home";
	await bootChrome(page, world, ".pinned-list [data-tab-id]");

	await expect(page.locator(".tab-list")).not.toHaveClass(/is-empty/);
	await expect(page.getByRole("treeitem", { name: "Acme Docs, 3 tabs" })).toBeVisible();
});

test("tabs an undo brings back open the stack they land in", async ({ page }) => {
	const world = stackWorld({ sidebarStackTabs: "true" });
	await bootChrome(page, world);
	const space = world.tabsBySpace[SPACE_1];
	const items = world.treeItemsBySpace[SPACE_1];
	const archived = ["tab-docs-setup", "tab-docs-api"];
	const sendState = (ids: string[] | null) =>
		page.evaluate(
			({ space, items, gone, spaceId }) => {
				const kept = (id: string) => !gone.includes(id);
				const state = { spaceId, activeTabId: "tab-alpha", tabs: space.filter((entry) => kept(entry.id)), folders: [], treeItems: items.filter((item) => kept(item.itemId)) };
				window.__lilo!.receive({ event: "browserStateChanged", changedSpaceId: spaceId, activeTabId: "tab-alpha", states: [state] });
			},
			{ space, items, gone: ids ?? [], spaceId: SPACE_1 },
		);

	await sendState(archived);
	await page.evaluate(() => window.__lilo!.receive({ event: "tabClosedUndoable", title: "API", count: 2, archivedIds: ["entry-1", "entry-2"] }));
	await page.locator(".undo-toast").getByRole("button", { name: "Reopen" }).click();
	await sendState(null);

	await expect(page.getByRole("treeitem", { name: "Acme Docs, 3 tabs" })).toHaveAttribute("aria-expanded", "true");
	await expect(row(page, "tab-docs-setup")).toBeVisible();
});

test("a tab that makes a stack joins it at once, with the pointer over the list", async ({ page }) => {
	const world = stackWorld({ sidebarStackTabs: "true" });
	const api = world.tabsBySpace[SPACE_1].find((entry) => entry.id === "tab-docs-api")!;
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].filter((entry) => entry !== api);
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].filter((item) => item.itemId !== api.id);
	await bootChrome(page, world);
	await row(page, "tab-docs-intro").hover();

	await page.evaluate(
		({ tabs, items, spaceId }) => {
			const state = { spaceId, activeTabId: "tab-docs-api", tabs, folders: [], treeItems: items };
			window.__lilo!.receive({ event: "browserStateChanged", changedSpaceId: spaceId, activeTabId: "tab-docs-api", states: [state] });
		},
		{ tabs: [...world.tabsBySpace[SPACE_1], api], items: [...world.treeItemsBySpace[SPACE_1], treeItem(api.id, SPACE_1, world.treeItemsBySpace[SPACE_1].length)], spaceId: SPACE_1 },
	);

	await expect(page.getByRole("treeitem", { name: "API · Acme Docs, 3 tabs" })).toBeVisible();
});
