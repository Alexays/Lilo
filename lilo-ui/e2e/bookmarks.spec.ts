import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

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
