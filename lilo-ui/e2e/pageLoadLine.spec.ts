import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import type { BridgeTabSnapshot } from "../src/lib/bridge/protocol";

function receive(page: Page, message: Record<string, unknown>): Promise<void> {
	return page.evaluate((m) => window.__lilo!.receive(m as never), message);
}

function load(page: Page, tab: BridgeTabSnapshot, isLoading: boolean, progress: number): Promise<void> {
	return receive(page, {
		event: "browserStatePatch",
		operations: [{ kind: "tabUpdated", spaceId: tab.spaceId, tab: { ...tab, isLoading, progress } }],
	});
}

test("a load past 300 ms shows its progress above the page only while no bar is left to show it", async ({ page }) => {
	const world = initialWorld();
	await bootChrome(page, { ...world, addressPlacement: "hidden" });
	const tab = world.tabsBySpace[SPACE_1][0];
	const line = page.locator(".page-load-line");
	await expect(line).toHaveCount(0);

	// Off the left edge, whose hover zone would bring the hidden sidebar back.
	await page.mouse.move(600, 400);
	await receive(page, { event: "sidebarVisibilityChanged", visible: false, width: 260 });
	await load(page, tab, true, 0.5);
	await expect(line).toHaveCSS("opacity", "0");
	await expect(line).toHaveClass(/shown/);
	await expect(line).toHaveCSS("opacity", "1");
	await expect(line).toHaveAttribute("style", /scaleX\(0\.5\)/);
	const box = (await line.boundingBox())!;
	const viewport = page.viewportSize()!;
	expect(box.height).toBe(2);
	expect(Math.abs(box.x + box.width / 2 - viewport.width / 2)).toBeLessThan(1);

	await load(page, tab, false, 1);
	await expect(line).toHaveAttribute("style", /scaleX\(1\)/);
	await expect(line).not.toHaveClass(/shown/);

	await receive(page, { event: "sidebarVisibilityChanged", visible: true, width: 260 });
	await expect(line).toHaveCount(0);
});
