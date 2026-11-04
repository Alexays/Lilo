import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

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

test("resting on the rail unfolds the sidebar over the page, and leaving it folds it back", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), sidebarRail: true });
	const sidebar = page.locator("#chrome-root > .sidebar");
	const rail = (await page.locator(".sidebar-rail").boundingBox())!;

	// An icon only shows its tooltip: the pointer is aiming at it.
	await page.locator(".rail-item[data-tab-id]").first().hover();
	await page.waitForTimeout(500);
	await expect(sidebar).toHaveClass(/rail-folded/);

	await page.mouse.move(rail.x + rail.width / 2, rail.y + rail.height - 120);
	await expect(sidebar).toHaveClass(/rail-expanded/);
	await expect(sidebar).not.toHaveAttribute("inert");

	// A click in the unfolded sidebar keeps it out until the pointer leaves.
	await sidebar.locator(".tab-item").nth(1).click();
	await page.waitForTimeout(400);
	await expect(sidebar).toHaveClass(/rail-expanded/);

	await page.mouse.move(900, 400);
	await expect(sidebar).toHaveClass(/rail-folded/);
	await expect(sidebar).toHaveAttribute("inert");
});
