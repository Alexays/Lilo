import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

async function receive(page: Page, message: Record<string, unknown>): Promise<void> {
	await page.evaluate((msg) => window.__lilo!.receive(msg), message);
}

test("the page toolbar carries navigation and the address on the right", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "right" });

	const toolbar = page.locator(".page-toolbar");
	await expect(toolbar.getByRole("button", { name: /back/i })).toBeVisible();
	await expect(toolbar.locator(".url-display")).toBeVisible();
	await expect(page.locator(".sidebar .url-display")).toHaveCount(0);
	const sidebar = await page.locator(".sidebar").boundingBox();
	const viewport = page.viewportSize()!;
	expect(Math.round(sidebar!.x + sidebar!.width)).toBe(viewport.width);
});

test("a row's preview card opens on the page side of a right sidebar", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "right" });
	const row = page.locator(".tab-list [data-tab-id]").first();
	await row.hover();
	const rowBox = (await row.boundingBox())!;
	const tabId = await row.getAttribute("data-tab-id");
	await expect.poll(() => sentCommands(page).then((c) => c.filter((m) => m.action === "requestTabPreview").length)).toBeGreaterThan(0);
	await receive(page, { event: "tabPreviewReady", tabId, image: "data:image/png;base64,iVBORw0KGgo=" });

	const card = (await page.locator(".tab-preview-card").boundingBox())!;
	expect(card.x + card.width).toBeLessThanOrEqual(rowBox.x);
});

test("moving the tabs from the host moves the chrome", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await expect(page.locator(".page-toolbar")).toHaveCount(0);

	await receive(page, { event: "tabLayoutChanged", position: "bottom", address: "page" });

	await expect(page.locator("html")).toHaveAttribute("data-tab-position", "bottom");
	await expect(page.locator(".page-toolbar")).toBeVisible();
});

test("the top strip lists today's tabs and switches on click", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top", addressPlacement: "page" });
	const pills = page.locator(".tab-strip .strip-tab");
	await expect(pills.first()).toBeVisible();
	const target = pills.nth(1);
	const tabId = await target.getAttribute("data-tab-id");

	await target.getByRole("button").first().click();

	const switches = (await sentCommands(page)).filter((c) => c.action === "switchTab");
	expect(switches.at(-1)?.payload).toEqual({ id: tabId });
});

test("dragging a pill after the next one reorders the strip", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top", addressPlacement: "page" });
	const pills = page.locator(".tab-strip .today-list .strip-tab");
	const first = (await pills.nth(0).boundingBox())!;
	const second = (await pills.nth(1).boundingBox())!;

	await page.mouse.move(first.x + 20, first.y + first.height / 2);
	await page.mouse.down();
	await page.mouse.move(second.x + second.width - 4, second.y + second.height / 2, { steps: 12 });
	await page.mouse.up();

	await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "commitSidebarDrop")).toBe(true);
});

test("the bottom dock opens its popovers upward", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "bottom" });
	const chip = page.locator(".space-chip");
	await chip.click();

	const popover = (await page.locator(".strip-popover").boundingBox())!;
	const dock = (await page.locator(".tab-strip").boundingBox())!;
	expect(popover.y + popover.height).toBeLessThanOrEqual(dock.y);
});

test("settings open as a floating column in the top position and stay open when the position changes", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top" });
	await receive(page, { event: "openSettings" });
	await expect(page.locator(".strip-panels.open")).toBeVisible();

	await receive(page, { event: "tabLayoutChanged", position: "bottom", address: "page" });

	await expect(page.locator(".strip-panels.open")).toBeVisible();
});

test("holding the header then dropping near the right edge moves the tabs right", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const header = (await page.locator(".sidebar-header").boundingBox())!;
	const viewport = page.viewportSize()!;

	await page.mouse.move(header.x + 40, header.y + header.height / 2);
	await page.mouse.down();
	await page.waitForTimeout(500);
	await expect(page.locator(".tab-edge-drag")).toBeVisible();
	await page.mouse.move(viewport.width - 20, viewport.height / 2, { steps: 8 });
	await expect(page.locator(".slot.right")).toBeVisible();
	await page.mouse.up();

	const sets = (await sentCommands(page)).filter((c) => c.action === "setSetting");
	expect(sets.at(-1)?.payload).toEqual({ key: "tabPosition", value: "right" });
	await expect(page.locator(".tab-edge-drag")).toHaveCount(0);
});

test("a quick drag on the header still moves the window", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const header = (await page.locator(".sidebar-header").boundingBox())!;

	await page.mouse.move(header.x + 40, header.y + header.height / 2);
	await page.mouse.down();
	await page.mouse.move(header.x + 80, header.y + header.height / 2, { steps: 4 });
	await page.mouse.up();

	expect((await sentCommands(page)).some((c) => c.action === "startWindowDrag")).toBe(true);
	await expect(page.locator(".tab-edge-drag")).toHaveCount(0);
});
