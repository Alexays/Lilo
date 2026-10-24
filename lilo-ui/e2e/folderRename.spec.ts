import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { treeItem } from "../src/stores/testFixtures";

const FOLDER = {
	id: "folder-docs",
	spaceId: SPACE_1,
	name: "Docs",
	color: "#5b7cff",
	isCollapsed: false,
};

// The fake host has no folder model, so the folder is pushed as a plain state snapshot.
async function bootWithFolder(page: Page) {
	const world = initialWorld();
	await bootChrome(page, world);
	await page.evaluate(
		(state) => window.__lilo!.receive({
			event: "browserStateChanged",
			changedSpaceId: state.spaceId,
			activeTabId: state.activeTabId,
			states: [state],
		}),
		{
			spaceId: SPACE_1,
			activeTabId: "tab-alpha",
			tabs: world.tabsBySpace[SPACE_1],
			folders: [FOLDER],
			treeItems: [
				...world.treeItemsBySpace[SPACE_1],
				treeItem(FOLDER.id, SPACE_1, 5, "unpinned", "folder"),
			],
		},
	);
	await page.locator(".folder-row").waitFor();
}

test("a folder name accepts spaces while renaming", async ({ page }) => {
	await bootWithFolder(page);

	await page.locator(".folder-row").hover();
	await page.locator(".folder-row .action-btn").first().click();
	const input = page.locator(".folder-title-input");
	await expect(input).toBeFocused();

	await input.fill("");
	await page.keyboard.type("Read later");

	await expect(input).toHaveValue("Read later");
	// The row must not have taken the space as its own activation.
	await expect(page.locator(".folder-row")).not.toHaveClass(/collapsed/);
});

test("a folder's title lines up with the tab titles", async ({ page }) => {
	await bootWithFolder(page);

	const folderTitle = (await page.locator(".folder-title").boundingBox())!;
	const tabTitle = (await page.locator('.tab-list > [data-dnd-item-id="tab-beta"] .tab-title').boundingBox())!;
	expect(folderTitle.x).toBeCloseTo(tabTitle.x, 0);

	const center = async (selector: string) => {
		const box = (await page.locator(selector).first().boundingBox())!;
		return box.x + box.width / 2;
	};
	expect(await center(".folder-icon svg")).toBeCloseTo(await center('.tab-list > [data-dnd-item-id="tab-beta"] .tab-icon'), 0);
});

test("a folder's buttons are the size of a tab row's buttons", async ({ page }) => {
	await bootWithFolder(page);
	await page.locator('[data-tab-id="tab-alpha"]').hover();

	const close = (await page.locator('[data-tab-id="tab-alpha"] .close-btn').boundingBox())!;
	await page.locator(".folder-row").hover();
	await expect(page.locator(".folder-actions")).toHaveCSS("opacity", "1");
	const edit = (await page.locator(".folder-row .action-btn").first().boundingBox())!;
	expect([edit.width, edit.height]).toEqual([close.width, close.height]);

	const glyph = (selector: string) => page.locator(selector).first().evaluate((svg) => ({
		size: svg.getAttribute("width"),
		strokes: [...new Set([...svg.querySelectorAll("[stroke-width]")].map((path) => path.getAttribute("stroke-width")))],
	}));
	const closeGlyph = await glyph('[data-tab-id="tab-alpha"] .close-btn svg');
	expect(await glyph(".folder-row .action-btn svg")).toEqual(closeGlyph);
	expect(await glyph(".folder-row .delete-btn svg")).toEqual(closeGlyph);
});

test("a folder's buttons stay shown while the keyboard is on them", async ({ page }) => {
	await bootWithFolder(page);
	await page.locator(".folder-row").focus();

	await page.keyboard.press("Tab");
	const edit = page.locator(".folder-row .action-btn").first();
	await expect(edit).toBeFocused();
	await expect(page.locator(".folder-actions")).toHaveCSS("opacity", "1");
	expect((await edit.boundingBox())!.width).toBeGreaterThan(0);
});
