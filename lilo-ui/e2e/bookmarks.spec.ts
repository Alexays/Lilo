import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
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
