import { expect, test } from "@playwright/test";
import { blankPoint, bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("the unfolded keep-awake label leaves the Space name readable in a narrow sidebar", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "200px"));
	await page.evaluate(() => window.__lilo!.receive({
		event: "keepAwakeChanged", keepsAwake: true, agents: [], tabIds: [], holdsLidClosed: true, helperStatus: "enabled",
	}));
	await expect(page.locator(".keep-awake-slot .pill.expanded")).toBeVisible();
	// The label unfolds over 240ms.
	await page.waitForTimeout(400);

	const name = (await page.locator(".space-pane").first().locator(".space-name").boundingBox())!;
	expect(name.width).toBeGreaterThanOrEqual(48);
	const label = page.locator(".keep-awake-slot .pill .text");
	await expect(label).toHaveCSS("text-overflow", "ellipsis");
});

test("a click outside the popover closes it and gives focus back to the chip", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({
		event: "keepAwakeChanged", keepsAwake: true, agents: [], tabIds: [], holdsLidClosed: false, helperStatus: "enabled",
	}));
	const pill = page.locator(".keep-awake-slot .pill");
	await expect(pill).toBeVisible();
	await pill.focus();
	await page.keyboard.press("Enter");
	await expect(page.locator(".popover.float-popover :focus")).toHaveCount(1);

	const point = await blankPoint(page, ".popover");
	await page.mouse.click(point.x, point.y);

	await expect(page.locator(".popover.float-popover")).toHaveCount(0);
	await expect(pill).toBeFocused();
});
