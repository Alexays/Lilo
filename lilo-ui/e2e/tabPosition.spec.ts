import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { folderWorld, initialWorld, SPACE_1 } from "./fixtures";

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
	await bootChrome(page, { ...initialWorld(), tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
	const pills = page.locator(".tab-strip .strip-tab");
	await expect(pills.first()).toBeVisible();
	const target = pills.nth(1);
	const tabId = await target.getAttribute("data-tab-id");

	await target.getByRole("tab").click();

	const switches = (await sentCommands(page)).filter((c) => c.action === "switchTab");
	expect(switches.at(-1)?.payload).toEqual({ id: tabId });
});

test("dragging a pill after the next one reorders the strip", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
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
	await bootChrome(page, { ...initialWorld(), tabPosition: "bottom" }, ".tab-strip");
	const chip = page.locator(".space-chip");
	await chip.click();

	const dock = (await page.locator(".tab-strip").boundingBox())!;
	// The popover measures itself once shown, then settles above the dock.
	await expect.poll(async () => {
		const popover = (await page.locator(".strip-popover").boundingBox())!;
		return popover.y + popover.height;
	}).toBeLessThanOrEqual(dock.y);
});

test("settings open as a floating column in the top position and stay open when the position changes", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top" }, ".tab-strip");
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

for (const position of ["left", "right", "top", "bottom"] as const) {
	test(`hidden tabs on the ${position} come back over the page from their edge, with navigation`, async ({ page }) => {
		const strip = position === "top" || position === "bottom";
		await bootChrome(page, { ...initialWorld(), tabPosition: position }, strip ? ".tab-strip" : ".tab-list [data-tab-id]");
		await page.mouse.move(600, 300);
		await receive(page, { event: "sidebarVisibilityChanged", visible: false, width: 260 });
		await expect(page.locator("html")).toHaveAttribute("data-tabs-hidden", "");
		const edges = () => page.evaluate(() => ["left", "right", "top", "bottom"].map((edge) => getComputedStyle(document.documentElement).getPropertyValue(`--chrome-content-${edge}`)));
		const before = await edges();

		const viewport = page.viewportSize()!;
		const point = { left: [2, 300], right: [viewport.width - 2, 300], top: [600, 2], bottom: [600, viewport.height - 2] }[position];
		await page.mouse.move(point[0], point[1]);

		const tabs = page.locator(strip ? ".tab-strip-host" : ".sidebar");
		await expect(tabs).toHaveClass(strip ? /strip-overlay/ : /sidebar-overlay/);
		expect(await edges()).toEqual(before);
		await expect(tabs.getByRole("button", { name: /back/i })).toBeVisible();
		await expect(tabs.locator(".url-display")).toBeVisible();
	});
}

test("a control-click on the header never lifts the tabs", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const header = (await page.locator(".sidebar-header").boundingBox())!;

	await page.keyboard.down("Control");
	await page.mouse.move(header.x + 40, header.y + header.height / 2);
	await page.mouse.down();
	await page.waitForTimeout(500);

	await expect(page.locator(".tab-edge-drag")).toHaveCount(0);
	await page.mouse.up();
	await page.keyboard.up("Control");
});

test("a click in the page closes a strip popover", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top" }, ".tab-strip");
	await page.locator(".space-chip").click();
	await expect(page.locator(".strip-popover")).toBeVisible();

	await receive(page, { event: "contentInteraction", isMouseDown: true });

	await expect(page.locator(".strip-popover")).toHaveCount(0);
});

test("the page toolbar centers the address on the page", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "bottom" }, ".tab-strip");
	const address = (await page.locator(".page-toolbar .url-display").boundingBox())!;
	const toolbar = (await page.locator(".page-toolbar").boundingBox())!;
	expect(Math.abs(address.x + address.width / 2 - (toolbar.x + toolbar.width / 2))).toBeLessThanOrEqual(2);
});

test("the active pill names its site when the strip holds the address", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top", addressPlacement: "tabs" }, ".tab-strip .strip-tab");
	const site = page.locator(".strip-tab.active .strip-tab-site");
	await expect(site).toBeVisible();
	expect((await site.textContent())?.trim()).not.toBe("");
});

test("the strip is one tab stop, walked with the arrow keys", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
	const rovers = page.locator(".tab-strip [data-roving]");
	await expect(rovers.locator('xpath=self::*[@tabindex="0"]')).toHaveCount(1);
	const stop = rovers.locator('xpath=self::*[@tabindex="0"]');
	await stop.focus();
	const before = await stop.evaluate((el) => el.closest("[data-tab-id]")?.getAttribute("data-tab-id"));

	await page.keyboard.press("ArrowRight");

	const after = await page.evaluate(() => document.activeElement?.closest("[data-tab-id], .strip-folder")?.getAttribute("data-tab-id") ?? "moved");
	expect(after).not.toBe(before);
	await expect(page.locator(".tab-strip [data-roving][tabindex='0']")).toHaveCount(1);
});

test("a pill dropped on a folder chip goes into the folder", async ({ page }) => {
	await bootChrome(page, { ...folderWorld(), tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
	const pill = page.locator('.today-list .strip-tab[data-tab-id="tab-beta"]');
	const chip = page.locator(".strip-folder", { hasText: "Docs" });
	const from = (await pill.boundingBox())!;
	const to = (await chip.boundingBox())!;

	await page.mouse.move(from.x + 20, from.y + from.height / 2);
	await page.mouse.down();
	await page.mouse.move(to.x + to.width / 2, to.y + to.height / 2, { steps: 14 });
	await expect(chip).toHaveClass(/drop-target/);
	await page.mouse.up();

	const drop = (await sentCommands(page)).filter((c) => c.action === "commitSidebarDrop").at(-1);
	expect(JSON.stringify(drop?.payload)).toContain("folder-docs");
});

test("a mouse wheel scrolls every tab of the strip sideways, pinned ones too", async ({ page }) => {
	await page.setViewportSize({ width: 720, height: 600 });
	await bootChrome(page, { ...folderWorld(), tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
	const scroller = page.locator(".tab-strip .scroller");
	const overflowing = await scroller.evaluate((el) => el.scrollWidth > el.clientWidth);
	test.skip(!overflowing, "the fixture fits at this width");
	const firstTab = scroller.locator(".strip-tab, .strip-folder").first();
	const before = (await firstTab.boundingBox())!.x;
	const box = (await scroller.boundingBox())!;
	await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);

	await page.mouse.wheel(0, 200);

	await expect.poll(() => scroller.evaluate((el) => el.scrollLeft)).toBeGreaterThan(0);
	await expect(scroller).toHaveClass(/overflow-start/);
	expect((await firstTab.boundingBox())!.x).toBeLessThan(before);
});

test("a pill squeezed to its icon shows no close button over its neighbor", async ({ page }) => {
	await page.setViewportSize({ width: 600, height: 600 });
	await bootChrome(page, { ...folderWorld(), tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
	const narrow = page.locator(".tab-strip .today-list .strip-tab:not(.active)").last();
	test.skip((await narrow.boundingBox())!.width >= 72, "the fixture leaves the pills wide at this width");

	await narrow.hover();

	await expect(narrow.locator(".strip-tab-close")).toBeHidden();
});

test("a locked folder unlocks from its chip", async ({ page }) => {
	const world = folderWorld();
	world.foldersBySpace![SPACE_1][0] = { ...world.foldersBySpace![SPACE_1][0], isLocked: true };
	await bootChrome(page, { ...world, tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
	await page.locator(".strip-folder", { hasText: "Docs" }).click();

	await page.locator(".strip-popover input[type=password]").fill("secret");
	await page.locator(".strip-popover .unlock-submit").click();

	const unlock = (await sentCommands(page)).filter((c) => c.action === "unlockTabFolder").at(-1);
	expect(unlock?.payload).toEqual({ id: "folder-docs", password: "secret" });
});
