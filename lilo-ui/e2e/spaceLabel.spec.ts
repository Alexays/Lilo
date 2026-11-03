import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("only the active Space's tile opens on its name, a long one cut short", async ({ page }) => {
	const world = initialWorld();
	world.spaces[0].name = "A Space name far too long for the bar";
	await bootChrome(page, world);
	const labels = page.locator(".bottom-bar .space-label");
	await expect(labels.first()).not.toHaveCSS("width", "0px");
	for (const label of (await labels.all()).slice(1)) await expect(label).toHaveCSS("width", "0px");
	const text = labels.first().locator(".space-label-text");
	expect((await text.boundingBox())!.width).toBeLessThanOrEqual(96);
});
