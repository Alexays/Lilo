import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, nestedFolderWorld } from "./fixtures";

const sidebarWidth = (page: Page) =>
	page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--sidebar-width"));

async function drag(page: Page, from: { x: number; y: number }, toX: number) {
	await page.mouse.move(from.x, from.y);
	await page.mouse.down();
	await page.mouse.move((from.x + toX) / 2, from.y, { steps: 4 });
	await page.mouse.move(toX, from.y, { steps: 4 });
	await page.mouse.up();
}

async function handleCenter(page: Page) {
	const box = (await page.locator(".sidebar-resize-handle, .sidebar-rail .resize-handle").first().boundingBox())!;
	return { x: box.x + box.width / 2, y: 600 };
}

test("dragging the edge under the detent folds the sidebar to its rail, and back out unfolds it at its width", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), sidebarWidth: 300 });
	const rail = page.locator(".sidebar-rail");

	await drag(page, await handleCenter(page), 100);
	await expect(rail.locator(".rail-item[data-tab-id]").first()).toBeVisible();
	await expect(page.locator("#chrome-root > .sidebar")).toHaveClass(/rail-folded/);
	expect(await sidebarWidth(page)).toBe("300px");
	expect((await sentCommands(page)).filter((c) => c.action === "setSidebarRail").at(-1)?.payload).toEqual({ rail: true });

	// Every icon is named for VoiceOver and the active one is marked.
	const labels = await rail.locator(".rail-item[data-tab-id]").evaluateAll((items) => items.map((item) => item.getAttribute("aria-label")));
	expect(labels.every(Boolean)).toBe(true);
	await expect(rail.locator(".rail-item[aria-current='page']")).toHaveCount(1);

	await drag(page, await handleCenter(page), 220);
	await expect(rail).toHaveCount(0);
	expect(await sidebarWidth(page)).toBe("300px");
	expect((await sentCommands(page)).filter((c) => c.action === "setSidebarRail").at(-1)?.payload).toEqual({ rail: false });
});

test("a folder on the rail lists its tabs beside it, and the sidebar stays folded", async ({ page }) => {
	await bootChrome(page, { ...nestedFolderWorld(), sidebarRail: true });
	const sidebar = page.locator("#chrome-root > .sidebar");
	const rail = (await page.locator(".sidebar-rail").boundingBox())!;

	// Resting on the rail never unfolds the sidebar.
	await page.mouse.move(rail.x + rail.width / 2, rail.y + rail.height - 120);
	await page.waitForTimeout(500);
	await expect(sidebar).toHaveClass(/rail-folded/);

	await page.locator(".sidebar-rail .rail-item[aria-label='Projects']").click();
	const popover = page.locator(".strip-popover");
	// Nested folders flatten into their tabs.
	await expect(popover.locator(".popover-row")).toHaveCount(2);
	expect((await popover.boundingBox())!.x).toBeGreaterThanOrEqual(rail.x + rail.width);

	await popover.locator(".popover-row").first().click();
	await expect(popover).toHaveCount(0);
	await expect(sidebar).toHaveClass(/rail-folded/);

	// A folder with nothing in it still opens, and says so.
	await page.locator(".sidebar-rail .rail-item[aria-label='Archive']").click();
	await expect(popover).toContainText("empty", { ignoreCase: true });
});

test("with the sidebar hidden, the edge reveals the rail, not the full sidebar", async ({ page }) => {
	// Off the left edge, whose hover zone would bring the hidden sidebar back.
	await page.mouse.move(600, 400);
	await bootChrome(page, { ...initialWorld(), sidebarRail: true, sidebarVisible: false });
	await expect(page.locator(".sidebar-rail")).toHaveCount(0);

	await page.mouse.move(2, 400);
	const rail = page.locator(".sidebar-rail");
	await expect(rail).toHaveClass(/floating/);
	await expect(page.locator("#chrome-root > .sidebar")).toHaveClass(/rail-folded/);
	await expect(page.locator("#chrome-root > .sidebar")).not.toHaveClass(/sidebar-overlay/);

	await page.mouse.move(900, 400);
	await expect(rail).toHaveCount(0);
});
