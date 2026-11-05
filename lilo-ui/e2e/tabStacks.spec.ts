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

test("a closed stack keeps its active page shown", async ({ page }) => {
	const world = stackWorld({ sidebarStackTabs: "true" });
	world.activeTabBySpace[SPACE_1] = "tab-docs-setup";
	await bootChrome(page, world);

	await expect(row(page, "tab-docs-setup")).toBeVisible();
	await expect(row(page, "tab-docs-intro")).toHaveCount(0);
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
