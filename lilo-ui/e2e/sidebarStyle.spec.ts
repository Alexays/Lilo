import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, deepFolderWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

const sidebar = ".sidebar-layout";
const activePane = ".space-pane:not(.pane-hidden)";

for (const colorScheme of ["light", "dark"] as const) {
	for (const [size, row] of [["streamlined", 36]] as const) {
		test(`${size} Streamlined sidebar in ${colorScheme} mode keeps controls and tab actions intact`, async ({ page }, testInfo) => {
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = initialWorld();
			world.settings = { interfaceStyle: size };
			await bootChrome(page, world);
			await expect(page.locator(sidebar)).toHaveClass(/streamlined-sidebar/);
			await expect(page.locator(`${activePane} .space-heading-name`)).toHaveText("Work");
			await expect(page.locator(`${activePane} .space-heading`)).toHaveCSS("height", `${20 + (row - 36) / 2}px`);
			const selected = page.locator('[data-tab-id="tab-alpha"]');
			await expect(selected).toHaveCSS("height", `${row}px`);
			await expect(selected.locator(".tab-title")).toHaveCSS("font-weight", "500");
			await expect(page.locator(`${activePane} .bookmark-tile`).first()).toBeVisible();
			if (size === "streamlined" && colorScheme === "light") await page.screenshot({ path: testInfo.outputPath("streamlined-sidebar.png") });
			await page.locator('[data-tab-id="tab-beta"]').click();
			expect((await sentCommands(page)).filter((m) => m.action === "switchTab").at(-1)?.payload).toMatchObject({ id: "tab-beta" });
		});
	}
}

test("Lilo stays the default and the appearance picker is keyboard-accessible and reversible", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await expect(page.locator(sidebar)).not.toHaveClass(/streamlined-sidebar/);
	await expect(page.locator(".space-heading")).toHaveCount(0);
	await expect(page.locator('[data-tab-id="tab-alpha"]')).toHaveCSS("height", "32px");
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.getByRole("button", { name: "Appearance", exact: true }).click();
	const picker = page.getByRole("radiogroup", { name: "Interface style", exact: true });
	const lilo = picker.getByRole("radio", { name: "Default", exact: true });
	await expect(lilo).toHaveAttribute("aria-checked", "true");
	await lilo.focus();
	await page.keyboard.press("ArrowRight");
	await expect(picker.getByRole("radio", { name: "Streamlined", exact: true })).toBeFocused();
	expect((await sentCommands(page)).filter((m) => m.action === "setSetting").at(-1)?.payload).toEqual({ key: "interfaceStyle", value: "streamlined" });
	await expect(page.locator(sidebar)).toHaveClass(/streamlined-sidebar/);
	await page.keyboard.press("Home");
	await expect(lilo).toBeFocused();
	await page.keyboard.press("Escape");
	await expect(page.locator(sidebar)).not.toHaveClass(/streamlined-sidebar/);
	await expect(page.locator(".space-heading")).toHaveCount(0);
	await expect(page.locator('[data-tab-id="tab-alpha"]')).toHaveCSS("height", "32px");
});

test("a cross-window settings change updates the visible Space heading and rows", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { interfaceStyle: "streamlined" } }));
	await expect(page.locator(`${activePane} .space-heading`)).toContainText("Work");
	await page.evaluate((space) => window.__lilo!.receive({ event: "spaceUpdated", ...space, name: "Design research" }), initialWorld().spaces[0]);
	await expect(page.locator(`${activePane} .space-heading`)).toContainText("Design research");
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: {} }));
	await expect(page.locator(".space-heading")).toHaveCount(0);
	await expect(page.locator('[data-tab-id="tab-alpha"]')).toHaveCSS("height", "32px");
});

test("the Streamlined sidebar keeps the end of a large list reachable after live style changes", async ({ page }) => {
	const world = initialWorld();
	const items = Array.from({ length: 1200 }, (_, i) => tab(`many-${i}`, SPACE_1, { title: `Research ${i}`, url: `https://example.com/${i}` }));
	world.tabsBySpace[SPACE_1] = items;
	world.treeItemsBySpace[SPACE_1] = items.map((item, i) => treeItem(item.id, SPACE_1, i));
	world.activeTabBySpace[SPACE_1] = items[0].id;
	world.settings = { interfaceStyle: "default", sidebarStackTabs: "false" };
	await bootChrome(page, world, '[data-tab-id="many-0"]');
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { interfaceStyle: "streamlined", sidebarStackTabs: "false" } }));
	const scroller = page.locator(`${activePane} .space-scroll`);
	await scroller.evaluate((el) => { el.scrollTop = el.scrollHeight; });
	await expect(page.locator('[data-tab-id="many-1199"]')).toBeInViewport();
	await expect(page.locator('[data-tab-id="many-1199"]')).toHaveCSS("height", "36px");
	expect(await page.locator('[data-tab-id^="many-"]').count()).toBeLessThan(200);
});

test("a narrow right sidebar truncates long Space names without overflowing", async ({ page }) => {
	await page.setViewportSize({ width: 700, height: 500 });
	const world = initialWorld();
	world.tabPosition = "right";
	world.sidebarWidth = 230;
	world.spaces[0].name = "A long Space name for research and design references";
	world.settings = { interfaceStyle: "streamlined" };
	await bootChrome(page, world);
	const heading = page.locator(`${activePane} .space-heading`);
	await expect(heading).toBeVisible();
	const widths = await heading.evaluate((el) => ({ content: el.scrollWidth, box: el.clientWidth }));
	expect(widths.content).toBeLessThanOrEqual(widths.box);
});


test("the shared style stays available with horizontal tabs while their geometry is preserved", async ({ page }) => {
	const world = initialWorld();
	world.tabPosition = "top";
	await bootChrome(page, world, ".tab-strip");
	const before = (await page.locator(".tab-strip").boundingBox())!.height;
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.getByRole("button", { name: "Appearance", exact: true }).click();
	const picker = page.getByRole("radiogroup", { name: "Interface style", exact: true });
	await picker.getByRole("radio", { name: "Streamlined", exact: true }).click();
	await expect(page.locator("html")).toHaveAttribute("data-interface-style", "streamlined");
	await page.keyboard.press("Escape");
	expect((await page.locator(".tab-strip").boundingBox())!.height).toBe(before);
});

test("the folded icon rail keeps its existing targets with Streamlined styling selected", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), sidebarRail: true, settings: { interfaceStyle: "streamlined" } }, ".sidebar-rail .rail-item[data-tab-id]");
	await expect(page.locator(".sidebar-rail .rail-item[data-tab-id]").first()).toHaveCSS("height", "30px");
	await expect(page.locator(".space-heading")).not.toBeInViewport();
});


for (const colorScheme of ["light", "dark"] as const) {
	test(`sections and nested folder colors follow the Streamlined sidebar in ${colorScheme} mode`, async ({ page }, testInfo) => {
		await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
		const world = deepFolderWorld();
		world.spaces[0].color = "#247a53";
		world.foldersBySpace![SPACE_1].forEach((folder, index) => { folder.color = index % 2 ? "#b43365" : "#416fbe"; });
		await bootChrome(page, world, ".folder-row");
		const folderIcons = page.locator(`${activePane} .folder-icon`);
		const originalIcons = await folderIcons.evaluateAll((icons) => icons.map((el) => getComputedStyle(el).color));
		const savedHues = await page.locator(`${activePane} .folder-edit-shell`).evaluateAll((els) => els.map((el) => el.getAttribute("style")));
		await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { interfaceStyle: "streamlined" } }));
		await expect(page.locator(`${activePane} .favorites-caption`)).toHaveCount(0);
		await expect(page.locator(`${activePane} .pinned-caption`)).toHaveCount(0);
		await expect(page.locator(`${activePane} .open-tabs-caption`)).toHaveText("Open tabs");
		for (const heading of await page.locator(`${activePane} .sidebar-section-caption`).all()) {
			const rule = await heading.evaluate((el) => getComputedStyle(el, "::after").backgroundColor);
			expect(rule).not.toBe("rgba(0, 0, 0, 0)");
		}
		await expect.poll(async () => {
			const lefts = await page.locator(`${activePane} .sidebar-section-caption`).evaluateAll((els) => els.map((el) => el.getBoundingClientRect().left));
			return Math.max(...lefts) - Math.min(...lefts);
		}).toBeLessThanOrEqual(1);
		const usableWidth = await page.locator(`${activePane} .space-scroll`).evaluate((el) => el.clientWidth);
		for (const heading of await page.locator(`${activePane} .sidebar-section-caption`).all()) {
			await expect.poll(async () => (await heading.boundingBox())!.width).toBeCloseTo(usableWidth, 0);
			await expect(heading.locator(".section-caption-name")).toHaveCSS("width", "1px");
		}
		const activeFolder = page.locator(`${activePane} .folder-row`).first();
		await activeFolder.focus();
		await activeFolder.press("ArrowLeft");
		await page.mouse.move(0, 0);
		await activeFolder.evaluate((el) => (el as HTMLElement).blur());
		await expect(activeFolder).toHaveClass(/contains-active.*collapsed|collapsed.*contains-active/);
		await expect(activeFolder).toHaveCSS("box-shadow", /0px 0px 0px 1px inset/);
		await expect(activeFolder).not.toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
		await page.screenshot({ path: testInfo.outputPath(`collapsed-active-${colorScheme}.png`) });
		await activeFolder.focus();
		await activeFolder.press("ArrowRight");
		await expect(activeFolder).toHaveCSS("box-shadow", "none");
		await expect(page.locator(`${activePane} .folder-row`).first()).toHaveCSS("height", "32px");
		await expect(page.locator('[data-tab-id="tab-alpha"]')).toHaveCSS("height", "32px");
		await expect(page.locator('[data-tab-id="tab-beta"]')).toHaveCSS("height", "36px");
		await expect(page.locator(`${activePane} .flat-folder`).first()).toBeVisible();
		const themedIcons = await folderIcons.evaluateAll((icons) => icons.map((el) => getComputedStyle(el).color));
		expect(themedIcons.length).toBeGreaterThan(5);
		expect(themedIcons.every((color, i) => color !== originalIcons[i])).toBe(true);
		expect(await page.locator(`${activePane} .folder-edit-shell`).evaluateAll((els) => els.map((el) => el.getAttribute("style")))).toEqual(savedHues);
		const navButton = page.locator(".sidebar-layout .nav-btn").first();
		await expect(navButton).toHaveCSS("width", "28px");
		await expect(navButton).toHaveCSS("height", "28px");
		await expect(page.locator(".sidebar-layout .nav-controls")).toHaveCSS("gap", "0px");
		if (colorScheme === "light") await page.screenshot({ path: testInfo.outputPath("sectioned-sidebar.png") });
		await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: {} }));
		await expect(page.locator(".sidebar-section-caption")).toHaveCount(0);
		await expect.poll(() => folderIcons.evaluateAll((icons) => icons.map((el) => getComputedStyle(el).color))).toEqual(originalIcons);
	});
}

test("empty sections add no captions and open tabs still get a section when there are no pins", async ({ page }) => {
	const world = initialWorld();
	world.settings = { interfaceStyle: "streamlined" };
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].filter((tab) => !tab.isPinned && !tab.isBookmarked);
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].filter((item) => item.section === "unpinned");
	await bootChrome(page, world);
	await expect(page.locator(`${activePane} .favorites-caption`)).toHaveCount(0);
	await expect(page.locator(`${activePane} .pinned-caption`)).toHaveCount(0);
	await expect(page.locator(`${activePane} .open-tabs-caption`)).toHaveText("Open tabs");
});


test("compact nested rows stay reachable in a large open folder after changing presets", async ({ page }) => {
	const world = deepFolderWorld();
	const items = Array.from({ length: 1200 }, (_, i) => tab(`nested-${i}`, SPACE_1, { title: `Reference ${i}`, url: `https://example.com/${i}` }));
	world.tabsBySpace[SPACE_1].push(...items);
	world.treeItemsBySpace[SPACE_1].push(...items.map((item, i) => treeItem(item.id, SPACE_1, 20 + i, "unpinned", "tab", "folder-level-5")));
	world.settings = { interfaceStyle: "default", sidebarStackTabs: "false" };
	await bootChrome(page, world, ".folder-row");
	const scroller = page.locator(`${activePane} .space-scroll`);
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { interfaceStyle: "streamlined", sidebarStackTabs: "false" } }));
	await scroller.evaluate((el) => { el.scrollTop = el.scrollHeight; });
	await expect(page.locator('[data-tab-id="nested-1199"]')).toBeInViewport();
	await expect(page.locator('[data-tab-id="nested-1199"]')).toHaveCSS("height", "32px");
	await expect(page.locator('[data-tab-id="tab-gamma"]')).toBeInViewport();
	expect(await page.locator('[data-tab-id^="nested-"]').count()).toBeLessThan(200);
});


test("folder placement keeps mixed manual order and aligns sibling folders and tabs", async ({ page }, testInfo) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	const world = initialWorld();
	world.settings = { interfaceStyle: "streamlined", sidebarStackTabs: "false" };
	world.foldersBySpace = { [SPACE_1]: [
		{ id: "parent", spaceId: SPACE_1, name: "Parent", color: "#247a53", isCollapsed: false },
		{ id: "child", spaceId: SPACE_1, name: "Child", color: "#be4162", isCollapsed: false },
		{ id: "loose", spaceId: SPACE_1, name: "Loose", color: "#247a53", isCollapsed: true },
	] };
	world.tabsBySpace[SPACE_1].push(tab("tab-root", SPACE_1, { title: "Outside folder" }));
	world.treeItemsBySpace[SPACE_1] = [
		treeItem("tab-wiki", SPACE_1, 0, "bookmarked"), treeItem("tab-home", SPACE_1, 1, "pinned"),
		treeItem("parent", SPACE_1, 2, "unpinned", "folder"),
		treeItem("tab-alpha", SPACE_1, 3, "unpinned", "tab", "parent"),
		treeItem("child", SPACE_1, 4, "unpinned", "folder", "parent"),
		treeItem("tab-gamma", SPACE_1, 5, "unpinned", "tab", "child"),
		treeItem("tab-beta", SPACE_1, 6, "unpinned", "tab", "parent"),
		treeItem("loose", SPACE_1, 7, "unpinned", "folder"), treeItem("tab-root", SPACE_1, 8),
	];
	await bootChrome(page, world, ".folder-row");
	const rows = page.locator(`${activePane} .tab-list-body .folder-row, ${activePane} .tab-list-body .tab-item`);
	await expect.poll(() => rows.evaluateAll((els) => els.map((el) => el.getAttribute("data-tab-id") || el.querySelector(".folder-title")!.textContent!.trim())))
		.toEqual(["Parent", "tab-alpha", "Child", "tab-gamma", "tab-beta", "Loose", "tab-root"]);
	const parent = page.locator(`${activePane} .folder-row`, { hasText: "Parent" });
	const child = page.locator(`${activePane} .folder-row`, { hasText: "Child" });
	const alpha = page.locator('[data-tab-id="tab-alpha"]');
	const beta = page.locator('[data-tab-id="tab-beta"]');
	const gamma = page.locator('[data-tab-id="tab-gamma"]');
	const left = async (selector: import("@playwright/test").Locator) => (await selector.boundingBox())!.x;
	await expect.poll(async () => Math.abs(await left(alpha.locator(".tab-title")) - await left(child.locator(".folder-title")))).toBeLessThanOrEqual(1);
	expect(await left(beta.locator(".tab-title"))).toBeCloseTo(await left(alpha.locator(".tab-title")), 0);
	expect(await left(alpha.locator(".tab-title")) - await left(parent.locator(".folder-title"))).toBeCloseTo(8, 0);
	expect(await left(gamma.locator(".tab-title")) - await left(child.locator(".folder-title"))).toBeCloseTo(8, 0);
	const titleBox = (await parent.locator(".folder-title").boundingBox())!;
	await parent.hover();
	await expect(parent.locator(".folder-actions")).toHaveCSS("opacity", "1");
	const hoveredTitle = (await parent.locator(".folder-title").boundingBox())!;
	expect(hoveredTitle.x).toBe(titleBox.x);
	expect(hoveredTitle.width).toBe(titleBox.width);
	const headingTitle = page.locator(`${activePane} .space-heading-name`);
	expect(await left(headingTitle)).toBeCloseTo(await left(parent.locator(".folder-title")), 0);
	const openGlyph = await parent.locator(".flat-folder path").getAttribute("d");
	await parent.focus();
	await parent.press("ArrowLeft");
	await expect(parent).toHaveClass(/contains-active.*collapsed|collapsed.*contains-active/);
	await expect(parent.locator(".flat-folder path")).not.toHaveAttribute("d", openGlyph!);
	await expect(parent).toHaveCSS("box-shadow", /inset/);
	await parent.press("ArrowRight");
	await expect(parent.locator(".flat-folder path")).toHaveAttribute("d", openGlyph!);
	await parent.press("ArrowDown");
	await expect(alpha).toBeFocused();
	await alpha.press("ArrowDown");
	await expect(child).toBeFocused();
	await child.press("ArrowDown");
	await expect(gamma).toBeFocused();
	await page.screenshot({ path: testInfo.outputPath("folder-placement.png") });
});


for (const appearance of ["default", "streamlined"] as const) {
	test(`${appearance} empty sidebar explains its reserved sections without replacing New Tab`, async ({ page }, testInfo) => {
		await page.emulateMedia({ reducedMotion: "reduce" });
		const world = initialWorld();
		world.settings = { interfaceStyle: appearance };
		world.tabsBySpace[SPACE_1] = [];
		world.treeItemsBySpace[SPACE_1] = [];
		world.activeTabBySpace[SPACE_1] = "";
		await bootChrome(page, world, ".sidebar-empty-slot");
		const pane = page.locator(activePane);
		await expect(pane.locator(".sidebar-empty-slot")).toHaveCount(3);
		await expect(pane.locator('[data-empty-section="favorites"]')).toContainText("Your most-used sites live here.");
		await expect(pane.locator('[data-empty-section="pinned"]')).toContainText("Keep tabs and folders for this Space.");
		await expect(pane.locator('[data-empty-section="open"]')).toContainText("New tabs appear here.");
		await expect(pane.locator(".new-tab-row")).toBeVisible();
		await expect(pane.locator(".favorites-section")).not.toHaveClass(/pinned/);
		await expect(pane.locator(".favorites-caption")).toHaveCount(0);
		await page.screenshot({ path: testInfo.outputPath("empty-sidebar.png") });
		if (appearance === "default") {
			const first = tab("first", SPACE_1, { title: "First tab", url: "https://example.com/first-tab" });
			await page.evaluate((state) => window.__lilo!.receive({
				event: "browserStateChanged", changedSpaceId: state.spaceId, activeTabId: state.activeTabId, states: [state],
			}), { spaceId: SPACE_1, activeTabId: first.id, tabs: [first], folders: [], treeItems: [treeItem(first.id, SPACE_1, 0)] });
			await expect(pane.locator('[data-empty-section="open"]')).toHaveCount(0);
			await expect(pane.locator('[data-empty-section="favorites"]')).toBeVisible();
			await expect(pane.locator('[data-empty-section="pinned"]')).not.toBeVisible();
		}
	});
}

test("a populated sidebar does not show reserved-section placeholders", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await expect(page.locator(`${activePane} .sidebar-empty-slot`)).toHaveCount(0);
});

test("a blank active New Tab still explains the empty open-tab area", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1] = [tab("blank", SPACE_1, { url: "", title: "" })];
	world.treeItemsBySpace[SPACE_1] = [treeItem("blank", SPACE_1, 0)];
	world.activeTabBySpace[SPACE_1] = "blank";
	await bootChrome(page, world, ".sidebar-empty-slot");
	await expect(page.locator(`${activePane} .sidebar-empty-slot`)).toHaveCount(3);
	await expect(page.locator(".command-bar-backdrop")).toHaveClass(/docked/);
});

test("the Space name labels a single divider that reaches the sidebar edge", async ({ page }) => {
	const world = initialWorld();
	world.settings = { interfaceStyle: "streamlined" };
	await bootChrome(page, world);
	const heading = page.locator(`${activePane} .space-heading`);
	await expect(heading).toContainText("Work");
	const headingRight = await heading.evaluate((el) => el.getBoundingClientRect().right);
	const sidebarRight = await page.locator(`${activePane} .space-scroll`).evaluate((el) => el.getBoundingClientRect().left + el.clientWidth);
	expect(headingRight).toBeCloseTo(sidebarRight, 0);
	expect(await heading.evaluate((el) => getComputedStyle(el, "::after").backgroundColor)).not.toBe("rgba(0, 0, 0, 0)");
	await expect(page.locator(".favorites-caption")).toHaveCount(0);
});


for (const appearance of ["default", "streamlined"]) {
	test(`a profile with no Spaces shows reserved sidebar areas in ${appearance} appearance`, async ({ page }, testInfo) => {
		const world = initialWorld();
		world.spaces = [];
		world.activeSpaceId = "";
		world.tabsBySpace = {};
		world.treeItemsBySpace = {};
		world.activeTabBySpace = {};
		world.settings = { interfaceStyle: appearance };
		await bootChrome(page, world, ".empty-profile-sidebar");
		const guide = page.locator(".empty-profile-sidebar");
		await expect(guide.locator(".sidebar-empty-slot")).toHaveCount(3);
		await expect(guide.locator("strong")).toHaveText(["Favorites", "Pinned tabs", "Open tabs"]);
		await expect(guide).toBeInViewport();
		await expect(page.getByRole("button", { name: "New Space", exact: true })).toBeVisible();
		await expect(page.locator(".pinned-list, .tab-list")).toHaveCount(0);
		expect((await sentCommands(page)).filter((message) => ["createSpace", "createTab"].includes(message.action))).toEqual([]);
		await page.screenshot({ path: testInfo.outputPath("blank-profile-sidebar.png") });
	});
}

for (const style of ["default", "streamlined"] as const) {
	test(`${style} tab actions are reachable by keyboard without moving the title`, async ({ page }) => {
		await page.emulateMedia({ reducedMotion: "reduce" });
		await bootChrome(page, { ...initialWorld(), settings: { interfaceStyle: style } });
		await page.mouse.move(0, 0);
		const row = page.locator('[data-tab-id="tab-beta"]');
		const title = row.locator(".tab-title");
		const before = (await title.boundingBox())!;
		const close = row.locator(".close-btn");
		await expect(close).toHaveAttribute("aria-hidden", "true");
		await row.focus();
		await expect(close).toHaveAttribute("aria-hidden", "false");
		const focused = (await title.boundingBox())!;
		expect(focused.x).toBe(before.x);
		expect(focused.width).toBe(before.width);
		await page.keyboard.press("Tab");
		await expect(close).toBeFocused();
		await page.keyboard.press("Enter");
		expect((await sentCommands(page)).filter((message) => message.action === "closeTab").at(-1)?.payload).toMatchObject({ id: "tab-beta" });
	});
}

for (const style of ["default", "streamlined"] as const) {
	for (const colorScheme of ["light", "dark"] as const) {
		test(`${style} narrow ${colorScheme} sidebar keeps long names and nested active folders usable`, async ({ page }, testInfo) => {
			await page.setViewportSize({ width: 700, height: 600 });
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = deepFolderWorld();
			world.sidebarWidth = 230;
			world.tabPosition = colorScheme === "dark" ? "right" : "left";
			world.settings = { interfaceStyle: style, sidebarStackTabs: "false" };
			await bootChrome(page, world, ".folder-row");
			const pane = page.locator(activePane);
			const scroll = pane.locator(".space-scroll");
			expect(await scroll.evaluate((el) => el.scrollWidth - el.clientWidth)).toBe(0);
			for (let level = 5; level >= 1; level--) {
				const folder = pane.locator(".folder-row", { hasText: `Level ${level} folder` });
				await folder.focus();
				await folder.press("ArrowLeft");
				await expect(folder).toHaveAttribute("aria-expanded", "false");
				await expect(folder).toHaveClass(/contains-active/);
				await expect(page.locator('[data-tab-id="tab-alpha"]')).not.toBeVisible();
				const box = (await folder.boundingBox())!;
				const title = (await folder.locator(".folder-title").boundingBox())!;
				expect(title.width).toBeGreaterThan(20);
				expect(title.x).toBeGreaterThanOrEqual(box.x);
				expect(title.x + title.width).toBeLessThanOrEqual(box.x + box.width);
				await folder.hover();
				await expect(folder.locator(".folder-actions")).toHaveCSS("opacity", "1");
				for (const button of await folder.locator(".folder-actions button").all()) {
					const action = (await button.boundingBox())!;
					expect(action.x).toBeGreaterThanOrEqual(box.x);
					expect(action.x + action.width).toBeLessThanOrEqual(box.x + box.width);
				}
				await folder.press("ArrowRight");
				await expect(page.locator('[data-tab-id="tab-alpha"]')).toBeVisible();
			}
			await page.mouse.move(350, 550);
			await pane.locator(".folder-row").first().evaluate((el) => (el as HTMLElement).blur());
			await page.screenshot({ path: testInfo.outputPath(`narrow-${style}-${colorScheme}.png`) });
		});
	}
}
