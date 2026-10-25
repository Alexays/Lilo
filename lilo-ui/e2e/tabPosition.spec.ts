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
