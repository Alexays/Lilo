import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

async function receive(page: Page, message: Record<string, unknown>): Promise<void> {
	await page.evaluate((msg) => window.__lilo!.receive(msg), message);
}

// Where the sidebar comes to rest, and the right edge it has when fully in view.
function sidebarBox(page: Page) {
	return page.locator(".sidebar").evaluate(async (el: HTMLElement) => {
		await Promise.all(el.getAnimations().map((animation) => animation.finished));
		const { left, right } = el.getBoundingClientRect();
		return { left, right, fullRight: el.offsetWidth };
	});
}

async function expectSidebarFullyShown(page: Page): Promise<void> {
	await expect.poll(async () => {
		const { left, right, fullRight } = await sidebarBox(page);
		return left === 0 && right === fullRight && fullRight > 0;
	}).toBe(true);
}

test("full screen keeps the sidebar fully in view at the left edge, with the setup left to resume", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "onboardingState", show: true, step: 3, usage: "browse" });
	await page.keyboard.press("Escape");
	await expect(page.locator(".pill")).toBeVisible();

	await receive(page, { event: "windowFullscreenChanged", isFullscreen: true });

	await expect(page.locator("#chrome-root")).toHaveClass(/fullscreen/);
	await expect(page.locator(".sidebar")).not.toHaveClass(/sidebar-hidden/);
	await expectSidebarFullyShown(page);
	await expect(page.locator(".tab-list [data-tab-id]").first()).toBeInViewport();
});

test("a sidebar hidden in full screen stays fully out of view until the left edge reveals it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "sidebarVisibilityChanged", visible: false, width: 260 });
	await receive(page, { event: "windowFullscreenChanged", isFullscreen: true });
	await expect.poll(async () => (await sidebarBox(page)).right).toBeLessThanOrEqual(0);

	await page.mouse.move(2, 300);

	await expectSidebarFullyShown(page);
	expect(await sentCommands(page)).toContainEqual(expect.objectContaining({ action: "sidebarOverlayChanged" }));
});

test("in full screen, without traffic lights, the sidebar toggle lines up with the URL field", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const toggle = page.locator(".sidebar-header .nav-btn").first();
	const reload = page.locator(".sidebar-header .nav-btn").last();
	const reloadBefore = await reload.boundingBox();
	const toggleTopBefore = (await toggle.boundingBox())!.y;

	await receive(page, { event: "windowFullscreenChanged", isFullscreen: true });
	await receive(page, { event: "windowChromeStateChanged", trafficLightsVisible: false });

	const urlLeft = (await page.locator(".url-surface").boundingBox())!.x;
	await expect.poll(async () => (await toggle.boundingBox())!.x).toBe(urlLeft);
	expect((await toggle.boundingBox())!.y).toBe(toggleTopBefore);
	expect(await reload.boundingBox()).toEqual(reloadBefore);
});
