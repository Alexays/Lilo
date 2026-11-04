import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab } from "../src/stores/testFixtures";
import type { AddressPlacement } from "../src/lib/bridge/protocol";

// The active tab can go both ways and shares its camera, so every button the top line can hold shows.
async function bootNarrow(page: Page, addressPlacement: AddressPlacement, sidebarWidth: number) {
	const world = { ...initialWorld(), addressPlacement, sidebarWidth };
	world.tabsBySpace[SPACE_1][0] = tab("tab-alpha", SPACE_1, {
		title: "Alpha Docs",
		url: "https://example.com/docs",
		canGoBack: true,
		canGoForward: true,
		isCameraActive: true,
	});
	await bootChrome(page, world);
	await page.evaluate(() => {
		const extension = { id: "ext-1", name: "Alpha", version: "1.0", description: "", isEnabled: true, hasPopup: true };
		window.__lilo!.receive({ event: "extensionsChanged", ids: [extension.id], extensions: [extension] });
		window.__lilo!.receive({ event: "settingsLoaded", settings: { agentsEnabled: "true" } });
	});
}

// Every visible button of the top line sits inside the sidebar, whole, apart from its neighbors.
async function expectLineFits(page: Page) {
	const sidebar = (await page.locator(".sidebar-viewport").boundingBox())!;
	const boxes = await page.locator(".sidebar-header button").evaluateAll((buttons) =>
		buttons.filter((b) => b.getClientRects().length).map((b) => b.getBoundingClientRect().toJSON() as DOMRect),
	);
	boxes.sort((a, b) => a.left - b.left);
	for (const [i, box] of boxes.entries()) {
		expect(box.width).toBeGreaterThanOrEqual(20);
		// The sidebar ends 8 px before the viewport's edge, at the page's inset.
		expect(box.right).toBeLessThanOrEqual(sidebar.x + sidebar.width - 8);
		if (i > 0) expect(box.left).toBeGreaterThanOrEqual(boxes[i - 1].right);
	}
	return boxes;
}

test("at its minimum with the address in the sidebar, the history buttons keep the top line and Agents ends the field", async ({ page }) => {
	await bootNarrow(page, "tabs", 203);
	const header = page.locator(".sidebar-header");
	await expect(page.locator(".url-trigger .agents-button")).toBeVisible();
	await expect(header.locator(".agents-button")).toBeHidden();

	const [toggle, back, forward, reload] = await expectLineFits(page);
	expect(back.left - toggle.right).toBeGreaterThanOrEqual(6);
	expect(forward.width).toBe(28);
	expect(reload.width).toBe(28);

	// A little wider, Agents is back on the top line.
	await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "231px"));
	await expect(header.locator(".agents-button")).toBeVisible();
	await expect(page.locator(".url-trigger .agents-button")).toBeHidden();
	await expectLineFits(page);

	// Its popover opens from the field, and the field's own command bar stays shut.
	await page.evaluate(() => {
		document.documentElement.style.setProperty("--sidebar-width", "203px");
		const conversation = { tabId: "tab-agent", agentId: "agent", title: "Example task", state: "idle", unread: false, spaceId: "space-1", spaceName: "Work", running: false };
		window.__lilo!.receive({ event: "conversationsChanged", conversations: [conversation] });
	});
	await page.locator(".url-trigger .agents-button").click();
	await expect(page.locator(".float-popover")).toBeVisible();
	await expect(page.locator(".command-bar-input")).toHaveCount(0);
});

test("with the address hidden, a too narrow sidebar widens to the line's minimum and the page's buttons wait behind one", async ({ page }) => {
	await bootNarrow(page, "hidden", 203);
	// Agents and the page actions button need 243 px beside the history buttons.
	await expect.poll(() => page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--sidebar-width"))).toBe("243px");

	const header = page.locator(".sidebar-header");
	await expect(header.locator(".nav-btn.history")).toHaveCount(3);
	await expect(header.locator(".forward")).toBeVisible();
	await expect(header.locator(".agents-button")).toBeVisible();
	const more = header.locator(".page-actions-btn");
	await expect(more).toBeVisible();
	await expect(header.locator(".url-actions")).toHaveCount(0);
	await expectLineFits(page);

	// Hovering a button never brings another over its neighbors.
	for (const button of [more, header.locator(".agents-button"), header.locator(".reload")]) {
		await button.hover();
		await expectLineFits(page);
	}

	// The page's buttons open in a row under the line, each whole.
	await more.click();
	const row = page.locator(".url-trigger.actions-only");
	await expect(row.locator(".permissions-btn")).toBeVisible();
	await expect(row.locator(".url-screenshot-btn")).toBeVisible();
	await expect(row.locator(".extension-menu-btn")).toBeVisible();
	const moreBox = (await more.boundingBox())!;
	expect((await row.boundingBox())!.y).toBeGreaterThan(moreBox.y + moreBox.height);
	await row.locator(".url-copy-btn").hover();
	const buttons = await row.locator(".permissions-btn, .url-action-btn, .extension-menu-btn").evaluateAll((items) =>
		items.map((item) => item.getBoundingClientRect().toJSON() as DOMRect),
	);
	for (let i = 1; i < buttons.length; i++) expect(buttons[i].left).toBeGreaterThanOrEqual(buttons[i - 1].right);

	await page.keyboard.press("Escape");
	await expect(row).toHaveCount(0);
});
