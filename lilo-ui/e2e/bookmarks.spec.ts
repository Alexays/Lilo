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

test("Rename from the menu edits a bookmark's name under the tiles, and Return confirms", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const pane = page.locator(".space-pane").first();

	await page.evaluate(() => window.__lilo!.receive({ event: "beginTabRename", id: "tab-wiki" }));
	const input = pane.locator(".bookmark-title-input");
	await expect(input).toBeFocused();
	await expect(input).toHaveValue("Marked Wiki");

	await input.fill("Wiki");
	await page.keyboard.press("Enter");

	await expect(input).toHaveCount(0);
	await expect(pane.locator(".bookmark-tile").first()).toHaveAttribute("aria-label", "Wiki");
	const renames = (await sentCommands(page)).filter((command) => command.action === "renameTab");
	expect(renames.map((command) => command.payload)).toEqual([{ id: "tab-wiki", title: "Wiki" }]);
});
