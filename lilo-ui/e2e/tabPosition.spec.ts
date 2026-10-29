import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { folderWorld, initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

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

for (const position of ["left", "right", "top", "bottom"] as const) {
	test(`the address can be hidden with tabs on the ${position} and the command bar still opens`, async ({ page }) => {
		const strip = position === "top" || position === "bottom";
		await bootChrome(page, { ...initialWorld(), tabPosition: position, addressPlacement: "hidden" }, strip ? ".tab-strip .strip-tab" : undefined);
		await expect(page.locator(".url-display")).toHaveCount(0);
		await expect(page.locator(".page-toolbar")).toHaveCount(position === "right" || position === "bottom" ? 1 : 0);
		// The page's buttons move up to the Space row.
		await expect(page.locator(".space-row-end .url-screenshot-btn")).toHaveCount(strip ? 0 : 1);

		await receive(page, { event: "toggleCommandBar", prefill: "https://example.com", selectAll: true });
		await expect(page.getByRole("combobox", { name: "Search or enter address" })).toHaveValue("https://example.com");
		await page.keyboard.press("Escape");
		await expect(page.locator(".url-display")).toHaveCount(0);

		await receive(page, { event: "sidebarVisibilityChanged", visible: false, width: 260 });
		await expect(page.locator(".url-display")).toHaveCount(0);
	});
}

test("the page's buttons cover the Space name on hover without truncating it", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), addressPlacement: "hidden" });
	const name = page.locator(".space-pane").first().locator(".space-name");
	const before = (await name.boundingBox())!.width;

	await page.locator(".space-pane").first().locator(".space-label").hover();
	await expect(page.locator(".space-row-end .url-actions-reveal")).toHaveCSS("opacity", "1");
	expect((await name.boundingBox())!.width).toBe(before);
});

test("with tabs on the left the sidebar and the address toolbar hide one without the other", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "left", addressPlacement: "page" });
	await expect(page.locator(".page-toolbar .url-display")).toBeVisible();

	await receive(page, { event: "sidebarVisibilityChanged", visible: false, width: 260 });
	await expect(page.locator(".page-toolbar .url-display")).toBeVisible();
	await expect(page.locator(".page-toolbar .lights-spacer")).toHaveCount(1);
	await expect(page.locator(".sidebar .url-display")).toHaveCount(0);

	await receive(page, { event: "sidebarVisibilityChanged", visible: true, width: 260 });
	await receive(page, { event: "toolbarVisibilityChanged", visible: false });
	await expect(page.locator(".page-toolbar")).toHaveCount(0);
	await expect(page.locator(".sidebar-layout")).not.toHaveClass(/compact-header/);
	await expect(page.locator(".url-display")).toHaveCount(0);
	// On the traffic lights' compact line.
	await expect(page.locator(".sidebar-header")).toHaveCSS("height", "40px");
});

test("the address setting offers Hidden on the right and can restore the address", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "right" });
	await receive(page, { event: "openSettings" });
	await page.locator(".section-nav-button").filter({ hasText: "Appearance" }).click();
	const address = page.getByRole("radiogroup", { name: "Address", exact: true });
	await expect(address.getByRole("radio", { name: "With the tabs", exact: true })).toHaveCount(0);
	await address.getByRole("radio", { name: "Hidden", exact: true }).click();
	expect((await sentCommands(page)).filter((command) => command.action === "setSetting").at(-1)?.payload).toEqual({ key: "addressPlacement", value: "hidden" });
	await receive(page, { event: "tabLayoutChanged", position: "right", address: "hidden" });
	await expect(address.getByRole("radio", { name: "Hidden", exact: true })).toHaveAttribute("aria-checked", "true");
	await expect(page.locator(".url-display")).toHaveCount(0);

	await address.getByRole("radio", { name: "Hidden", exact: true }).focus();
	await page.keyboard.press("ArrowLeft");
	expect((await sentCommands(page)).filter((command) => command.action === "setSetting").at(-1)?.payload).toEqual({ key: "addressPlacement", value: "page" });
	await receive(page, { event: "tabLayoutChanged", position: "right", address: "page" });
	await expect(page.locator(".page-toolbar .url-display")).toBeVisible();
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

test("the sidebar going away after the strip came keeps the strip clickable", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "tabLayoutChanged", position: "top", address: "tabs" });
	await expect(page.locator(".tab-strip .strip-tab").first()).toBeVisible();
	const strip = (await page.locator(".tab-strip-host").boundingBox())!;

	// The old sidebar's teardown can trail the strip's mount: replay its removals last, as a live window sends them.
	await expect.poll(async () => {
		const zones = new Map<string, { y: number; width: number; height: number }>();
		const removals: string[] = [];
		for (const command of await sentCommands(page)) {
			if (command.action === "registerInteractiveZones") {
				for (const zone of command.payload.zones as { id: string; y: number; width: number; height: number }[]) zones.set(zone.id, zone);
			} else if (command.action === "removeInteractiveZone") {
				removals.push(command.payload.id as string);
			}
		}
		for (const id of removals) zones.delete(id);
		return [...zones.values()].some((zone) => zone.y <= strip.y + 1 && zone.height >= strip.height - 1 && zone.width >= strip.width - 1);
	}).toBe(true);
});

test("many squeezed pills never slide under the Settings tab", async ({ page }) => {
	await page.setViewportSize({ width: 700, height: 500 });
	const world = initialWorld();
	for (let index = 0; index < 30; index++) {
		world.tabsBySpace[SPACE_1].push(tab(`tab-extra-${index}`, SPACE_1, { title: `Extra ${index}` }));
		world.treeItemsBySpace![SPACE_1].push(treeItem(`tab-extra-${index}`, SPACE_1, 10 + index));
	}
	await bootChrome(page, { ...world, tabPosition: "top", addressPlacement: "tabs" }, ".tab-strip .strip-tab");
	await receive(page, { event: "openSettings" });
	const settings = (await page.locator(".tab-strip .strip-surface").boundingBox())!;

	const overlapping = await page.locator(".tab-strip .today-list .strip-tab").evaluateAll(
		(pills, edge) => pills.filter((pill) => { const box = pill.getBoundingClientRect(); return box.right > edge.left + 1 && box.left < edge.right - 1; }).length,
		{ left: settings.x, right: settings.x + settings.width },
	);
	expect(overlapping).toBe(0);
});

test("an active favorite names its site without sliding over the favorites beside it", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), activeTabBySpace: { [SPACE_1]: "tab-wiki" }, tabPosition: "top", addressPlacement: "tabs" }, ".tab-strip .strip-tab");
	const groups = await page.locator(".tab-strip .scroller > .group").evaluateAll((els) => els.map((el) => [el.getBoundingClientRect().width, el.scrollWidth]));

	for (const [width, scrollWidth] of groups) expect(scrollWidth, "a group holds its pills").toBeLessThanOrEqual(Math.ceil(width) + 1);
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

test("a pill aimed at a pinned folder chip keeps the row still and drops into the folder", async ({ page }) => {
	const world = folderWorld();
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].map((item) =>
		item.itemId === "folder-docs" || item.itemId === "tab-alpha" ? { ...item, section: "pinned" } : item);
	await bootChrome(page, { ...world, tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
	const pill = (await page.locator('.strip-tab[data-tab-id="tab-beta"]').boundingBox())!;
	const chip = page.locator(".strip-folder", { hasText: "Docs" });
	const y = pill.y + pill.height / 2;

	await page.mouse.move(pill.x + 10, y);
	await page.mouse.down();
	await page.mouse.move(pill.x - 30, y, { steps: 8 });
	const chipBox = (await chip.boundingBox())!;
	await page.mouse.move(chipBox.x + chipBox.width / 2, y, { steps: 8 });
	await expect(chip).toHaveClass(/drop-target/);
	// The placeholder stays in the row: the chip must not slide out from under the pointer.
	await expect(page.locator('.tab-strip [data-dnd-item-id="dnd-shadow:tab-beta"]')).toHaveCount(1);
	expect((await chip.boundingBox())!.x).toBe(chipBox.x);
	await page.mouse.up();

	const drop = (await sentCommands(page)).find((c) => c.action === "commitSidebarDrop");
	expect(drop?.payload).toMatchObject({ id: "tab-beta", section: "pinned", parentFolderId: "folder-docs" });
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

test("settings open as a page with its navigation and an active pill in the top strip, across a position change", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top" }, ".tab-strip");
	await receive(page, { event: "openSettings" });

	const pill = page.locator(".tab-strip .strip-surface");
	await expect(pill.getByRole("tab", { name: "Settings" })).toHaveAttribute("aria-selected", "true");
	await expect(page.locator(".tab-strip .strip-tab.active")).toHaveCount(0);
	await expect(page.locator(".ui-shell-frame .ui-shell-frame-nav .section-nav-button")).toHaveCount(9);
	await expect(page.locator(".strip-panels.open")).toHaveCount(0);
	await expect(page.locator("html")).not.toHaveAttribute("data-strip-panel-open");

	await receive(page, { event: "tabLayoutChanged", position: "bottom", address: "page" });

	await expect(pill).toBeVisible();
	await expect(page.locator(".ui-shell-frame-nav")).toBeVisible();
	await expect(page.locator(".strip-panels.open")).toHaveCount(0);
});

test("a narrow window narrows the settings navigation to icons named by tooltips, and widens it back", async ({ page }) => {
	await page.setViewportSize({ width: 700, height: 800 });
	await bootChrome(page, { ...initialWorld(), tabPosition: "top" }, ".tab-strip");
	await receive(page, { event: "openSettings" });

	const privacy = page.locator(".ui-shell-frame-nav .section-nav-button").filter({ hasText: "Privacy" });
	await expect(page.locator(".ui-shell-frame-nav .section-nav-toolbar")).toHaveCount(0);
	await privacy.hover();
	await expect(page.locator(".lilo-tooltip-title").filter({ hasText: /^Privacy$/ })).toBeVisible();

	await page.setViewportSize({ width: 1300, height: 800 });
	await expect(page.locator(".ui-shell-frame-nav .section-nav-toolbar")).toBeVisible();
	await expect(privacy.locator(".section-nav-label")).toHaveCSS("position", "static");
});

test("the settings pill's close button closes settings", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top" }, ".tab-strip");
	await receive(page, { event: "openSettings" });

	await page.locator(".strip-surface").getByRole("button", { name: "Close" }).click();

	await expect(page.locator(".ui-shell-frame")).toHaveCount(0);
	await expect(page.locator(".strip-surface")).toHaveCount(0);
	await expect(page.locator(".tab-strip .strip-tab.active")).toHaveAttribute("data-tab-id", "tab-alpha");
});

test("history in the strip shows as the active tab, and its close button closes it", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top" }, ".tab-strip");
	await receive(page, { event: "openHistory" });

	await expect(page.locator(".strip-surface")).toContainText("History");
	await expect(page.locator(".tab-strip .strip-tab.active")).toHaveCount(0);
	await page.locator(".strip-surface").getByRole("button", { name: "Close" }).click();

	await expect(page.locator(".ui-shell-frame")).toHaveCount(0);
	await expect(page.locator(".strip-surface")).toHaveCount(0);
	await expect(page.locator(".tab-strip .strip-tab.active")).toHaveAttribute("data-tab-id", "tab-alpha");
});

test("clicking another tab in the strip leaves settings for it", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top", addressPlacement: "page" }, ".tab-strip .strip-tab");
	await receive(page, { event: "openSettings" });
	await expect(page.locator(".strip-surface")).toBeVisible();

	await page.locator('.tab-strip .strip-tab[data-tab-id="tab-beta"]').getByRole("tab").click();

	await expect(page.locator(".ui-shell-frame")).toHaveCount(0);
	await expect(page.locator(".strip-surface")).toHaveCount(0);
	const switches = (await sentCommands(page)).filter((c) => c.action === "switchTab");
	expect(switches.at(-1)?.payload).toEqual({ id: "tab-beta" });
});

test("settings in the sidebar layout keep their navigation in the sidebar, with no strip pill", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "openSettings" });

	await expect(page.locator(".sidebar .section-nav-button")).toHaveCount(9);
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
	await expect(page.locator(".ui-shell-frame-nav")).toHaveCount(0);
	await expect(page.locator(".strip-surface")).toHaveCount(0);
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
