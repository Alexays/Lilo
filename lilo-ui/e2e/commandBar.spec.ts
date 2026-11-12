import { expect, test, type Locator, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

test("Enter runs the highlighted tab even when an engine suggestion shows as ghost text", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	await input.pressSequentially("beta");

	// Typed slowly, a prefix asks first: the reply and Enter must come after the full query's debounced search.
	await expect
		.poll(async () => (await sentCommands(page)).some((c) => c.action === "searchSuggestions" && c.payload.query === "beta"))
		.toBe(true);
	await page.evaluate(() =>
		window.__lilo!.receive({ event: "searchSuggestions", query: "beta", suggestions: ["beta blockers"] }),
	);
	const highlighted = page.locator(".command-bar-result.selected");
	await expect(highlighted).toContainText("Beta Mail");

	await input.press("Enter");

	await expect
		.poll(async () => (await sentCommands(page)).filter((c) => c.action === "switchTab").map((c) => c.payload.id))
		.toEqual(["tab-beta"]);
	expect((await sentCommands(page)).some((c) => c.action === "navigate")).toBe(false);
});

test("the Esc hint says Back while Escape leaves a scope or a tab move", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	const escHint = page.locator(".command-bar-footer > .key-hint");
	await expect(escHint).toHaveText("Closeesc");

	await input.fill("@beta");
	await expect(escHint).toHaveText("Backesc");
	await input.press("Meta+m");
	await expect(input).toHaveAttribute("placeholder", /Space/);
	await input.press("Escape");
	await expect(input).toHaveValue("beta");
	await expect(page.locator(".scope-token")).toHaveText("Tabs");
	await input.press("Escape");
	await expect(escHint).toHaveText("Closeesc");
});

test("Escape closing the command bar hands the keyboard back to the page", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	await input.fill("@beta");
	await input.press("Escape");
	expect((await sentCommands(page)).some((c) => c.action === "focusPage")).toBe(false);

	await input.press("Escape");

	await expect(page.locator(".command-bar")).toBeHidden();
	await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "focusPage")).toBe(true);
});

for (const prefix of [":", "<", ">"]) {
	test(`Escape in the ${prefix} scope leaves the scope before closing`, async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
		const input = page.locator(".command-bar-input");
		await input.fill(`${prefix}beta`);

		await input.press("Escape");

		await expect(input).toHaveValue("beta");
		await expect(page.locator(".command-bar")).toBeVisible();
	});
}

test("the footer names what Enter does on an action, the row keeps its shortcut", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").fill(":");

	const selected = page.locator(".command-bar-result.selected");
	await expect(selected).toContainText("New Tab");
	await expect(selected.locator(".result-shortcut")).toHaveText("⌘T");
	await expect(page.locator(".command-bar-footer .key-hint").first()).toHaveText("Run↩");
});

test("row shortcuts and footer keys spell keys with the same symbols", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");

	await input.fill(":sidebar");
	await expect(page.locator(".command-bar-result.selected .result-shortcut")).toHaveText("⇧⌘S");
	await input.fill(":terminal");
	await expect(page.locator(".command-bar-result", { hasText: "New Terminal" }).locator(".result-shortcut")).toHaveText("⌃`");

	// The Actions token stays until it is cleared, as a chip press or Backspace at the start does.
	await input.fill("");
	await input.press("Backspace");
	await input.fill("beta");
	await expect(page.locator(".command-bar-footer kbd")).toHaveText(["↩", "⌘↩", "⌥↩", "⇧↩", "⌘C", "⌘⌫", "⌘M", "esc"]);
});

test("scope chips are set in the footer hints' size", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const footerSize = await page.locator(".command-bar-footer .key-hint").first().evaluate((el) => getComputedStyle(el).fontSize);

	await expect(page.locator(".scope-hint").nth(1)).toHaveCSS("font-size", footerSize);
	await expect(page.locator(".scope-hint-prefix").first()).toHaveCSS("font-size", footerSize);
});

test("an empty scope says what the scope holds, not that nothing matched", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").fill("<");
	await page.evaluate(() => window.__lilo!.receive({ event: "archivedTabs", tabs: [] }));

	await expect(page.locator(".command-bar-empty-title")).toHaveText("Archive");

	await page.locator(".command-bar-input").fill("< zzz");
	await expect(page.locator(".command-bar-empty-title")).toHaveText("No matches");
});

test("arrows walk a long list under a resting pointer without the pointer taking the selection back", async ({ page }) => {
	await page.setViewportSize({ width: 1000, height: 600 });
	const world = initialWorld();
	for (let i = 0; i < 30; i++) {
		world.tabsBySpace[SPACE_1].push(tab(`tab-x${i}`, SPACE_1, { title: `Extra ${i}` }));
		world.treeItemsBySpace[SPACE_1].push(treeItem(`tab-x${i}`, SPACE_1, 10 + i));
	}
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	await input.fill("@");
	const rows = page.locator(".command-bar-result");
	await expect(rows).toHaveCount(8);
	const titles = await rows.locator(".result-title").allTextContents();
	const row = (await rows.nth(3).boundingBox())!;
	await page.mouse.move(row.x + 50, row.y + 10);
	const selected = page.locator(".command-bar-result.selected .result-title");
	await expect(selected).toHaveText(titles[3]);

	// The list scrolls under the still pointer on the way down, and back up when the selection wraps.
	for (let step = 1; step <= 8; step++) {
		await input.press("ArrowDown");
		// The engine replays the pointer over what scrolled under it a beat after the scroll.
		await page.waitForTimeout(120);
		await expect(selected).toHaveText(titles[(3 + step) % 8]);
	}
});

async function showTerminal(page: Page, title: string, spaceName: string, gitBranch: string) {
	await page.setViewportSize({ width: 1100, height: 640 });
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").fill(">");
	await page.evaluate((terminal) => window.__lilo!.receive({
		event: "terminalCompletionResults",
		query: "",
		items: [],
		terminals: [{
			tabId: "t1", command: "", state: "idle", awaitingInputSince: 0, startedAt: 0, exitCode: 0, duration: 0, spaceId: "space-2", ...terminal,
		}],
	}), { title, spaceName, gitBranch });
	const row = page.locator(".command-bar-result").filter({ hasText: title });
	await expect(row).toBeVisible();
	return row;
}

const fitsWhole = (el: Element) => el.scrollWidth <= el.clientWidth;

test("a helper chip that fits beside the title shows whole", async ({ page }) => {
	const row = await showTerminal(page, "zsh", "A Space With A Long Name", "feature/some-long-branch-name");

	expect(await row.locator(".result-helper").evaluate(fitsWhole)).toBe(true);
});

test("a long helper chip gives way before the title gets too narrow", async ({ page }) => {
	const row = await showTerminal(
		page,
		"zsh in a folder with a fairly long name that keeps going",
		"A Space With A Long Name",
		"feature/some-really-long-branch-name-that-keeps-going",
	);

	expect(await row.locator(".result-helper").evaluate(fitsWhole)).toBe(false);
	// Layout width: the panel's opening scale would shrink a bounding box.
	expect(await row.locator(".result-main").evaluate((el) => el.clientWidth)).toBeGreaterThanOrEqual(160);
});

test("the scope chips stand down while the Space picker of a tab move is up", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	await input.fill("@beta");
	await input.press("Meta+m");
	await expect(input).toHaveAttribute("placeholder", /Space/);

	const historyChip = page.locator(".scope-hint", { hasText: "History" });
	await expect(historyChip).toBeDisabled();
	await historyChip.click({ force: true });

	await expect(input).toHaveValue("");
	await expect(input).toHaveAttribute("placeholder", /Space/);
	await expect(page.locator(".command-bar-result").first()).toContainText("Play");
});

test("the ghost completion shows only with the caret at the end, and only then does Tab take it", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].find((t) => t.id === "tab-beta")!.url = "https://github.com/";
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	const ghost = page.locator(".command-bar-autocomplete");
	await input.pressSequentially("git");
	await expect(ghost).toHaveText("github.com");

	await input.press("Home");
	await expect(ghost).toHaveCount(0);
	await expect(page.locator(".command-bar-footer kbd", { hasText: /^Tab$/ })).toHaveCount(0);
	await input.press("Tab");
	await expect(input).toHaveValue("git");

	await input.press("End");
	await expect(ghost).toHaveText("github.com");
	await input.press("Tab");
	await expect(input).toHaveValue("github.com");
});

test("Backspace over the ghost completion removes the completion and keeps the typed text", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].find((t) => t.id === "tab-beta")!.url = "https://github.com/";
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	const ghost = page.locator(".command-bar-autocomplete");
	await input.pressSequentially("gi");
	await expect(ghost).toHaveText("github.com");

	await input.press("Backspace");
	await expect(input).toHaveValue("gi");
	await expect(ghost).toHaveCount(0);

	await input.press("Backspace");
	await expect(input).toHaveValue("g");
});

async function showClosedTerminal(page: Page, closedMinutesAgo: number) {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").fill(">");
	await page.evaluate((closedAt) => window.__lilo!.receive({
		event: "terminalCompletionResults",
		query: "",
		items: [],
		terminals: [],
		closedTerminals: [{ index: 0, title: "old shell", resumeCommand: "", gitBranch: "", folder: "~/x", closedAt, hasScreen: false, spaceName: "Work" }],
	}), Date.now() - closedMinutesAgo * 60_000);
	return page.locator(".command-bar-result", { hasText: "old shell" }).locator(".result-subtitle");
}

test("a closed terminal says when it closed like the tab switcher does", async ({ page }) => {
	await expect(await showClosedTerminal(page, 61)).toHaveText("Closed 1 h ago");
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("a closed terminal says il y a 1 h, without minutes", async ({ page }) => {
		await expect(await showClosedTerminal(page, 61)).toHaveText("Fermé il y a 1 h");
	});

	test("every scope chip stays inside a narrow bar", async ({ page }) => {
		await page.setViewportSize({ width: 600, height: 400 });
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
		const toolbar = (await page.locator(".command-bar-scopes").boundingBox())!;

		const chips = await page.locator(".scope-hint").all();
		expect(chips.length).toBe(7);
		for (const chip of chips) {
			const box = (await chip.boundingBox())!;
			expect(box.x + box.width).toBeLessThanOrEqual(toolbar.x + toolbar.width);
			expect(box.y + box.height).toBeLessThanOrEqual(toolbar.y + toolbar.height);
		}
	});

	test("a blank tab's result reads Nouvel onglet", async ({ page }) => {
		const world = initialWorld();
		world.tabsBySpace[SPACE_1].push(tab("tab-blank", SPACE_1, { url: "", title: "" }));
		world.treeItemsBySpace[SPACE_1].push(treeItem("tab-blank", SPACE_1, 5));
		await bootChrome(page, world);
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));

		const results = page.locator(".command-bar-result");
		await expect(results.filter({ hasText: "Beta Mail" })).toHaveCount(1);
		await expect(results.filter({ hasText: "Nouvel onglet" }).first()).toBeVisible();
		await expect(results.filter({ hasText: "New Tab" })).toHaveCount(0);
	});
});

for (const [query, name, action] of [
	["reader", "Reader View", "toggleReader"],
	["find on page", "Find on Page", "showFindBar"],
	["copy url", "Copy Page URL", "copyPageURL"],
	["pin tab", "Pin or Unpin Tab", "togglePinActiveTab"],
	["duplicate", "Duplicate Tab", "duplicateActiveTab"],
	["capture area", "Capture Selected Area", "screenshotPage"],
] as const) {
	test(`the command bar runs ${name} from ":${query}"`, async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
		const input = page.locator(".command-bar-input");
		await input.fill(`:${query}`);

		await expect(page.locator(".command-bar-result.selected")).toContainText(name);
		await input.press("Enter");

		await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === action)).toBe(true);
		await expect(page.locator(".command-bar")).toBeHidden();
	});
}

test("the command bar opens the downloads list, its row naming the Downloads keys", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	await input.fill(":downloads");

	await expect(page.locator(".command-bar-result.selected")).toContainText("Show Downloads");
	await expect(page.locator(".command-bar-result.selected .result-shortcut")).toHaveText("⌥⌘L");
	await input.press("Enter");

	await expect(page.locator("section[aria-label=\"Downloads\"]")).toBeVisible();
});

for (const [how, click] of [
	["a Command-click", { modifiers: ["Meta"] }],
	["a middle click", { button: "middle" }],
] satisfies [string, Parameters<Locator["click"]>[0]][]) {
	test(`${how} on a row opens it in a new tab, as Command-Return does`, async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
		await page.locator(".command-bar-input").fill("example.com");

		await page.locator(".command-bar-result", { hasText: "example.com" }).first().click(click);

		await expect
			.poll(async () => (await sentCommands(page)).filter((c) => c.action === "createTab").map((c) => c.payload.url))
			.toEqual(["https://example.com"]);
		expect((await sentCommands(page)).some((c) => c.action === "navigate")).toBe(false);
	});
}

test("a result's favicon hides its initial, which comes back when the favicon fails", async ({ page }) => {
	const world = initialWorld();
	const transparent = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].map((tab) =>
		tab.id === "tab-alpha" ? { ...tab, faviconDataURL: transparent } : tab.id === "tab-beta" ? { ...tab, faviconDataURL: "data:image/png;base64,broken" } : tab,
	);
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const alpha = page.locator(".result-icon-site", { has: page.locator(`img[src^="data:image/png;base64,iVBOR"]`) }).first();
	await expect(alpha.locator(".result-favicon-fallback")).toBeHidden();
	const beta = page.locator(".result-icon-site", { has: page.locator('img[src="data:image/png;base64,broken"]') }).first();
	await expect(beta.locator(".result-favicon-fallback")).toBeVisible();
});

test("bookmarks sit in one strip of chips that the side arrows walk and the up and down arrows leave", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].push(tab("tab-notes", SPACE_1, { title: "Marked Notes", isBookmarked: true }));
	world.treeItemsBySpace[SPACE_1].push(treeItem("tab-notes", SPACE_1, 5, "bookmarked"));
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));

	const chips = page.locator(".command-bar-strip .command-bar-chip");
	await expect(chips).toHaveCount(2);
	const [first, second] = [(await chips.nth(0).boundingBox())!, (await chips.nth(1).boundingBox())!];
	expect(second.y).toBe(first.y);
	expect(second.x).toBeGreaterThan(first.x + first.width);
	expect((await chips.nth(0).locator(".result-icon").boundingBox())!.height).toBe(20);
	await expect(chips.nth(0)).toHaveClass(/selected/);

	const input = page.locator(".command-bar-input");
	await input.press("ArrowRight");
	await expect(chips.nth(1)).toHaveClass(/selected/);
	await input.press("ArrowDown");
	await expect(page.locator(".command-bar-chip.selected")).toHaveCount(0);
	await expect(page.locator(".command-bar-result.selected")).toHaveCount(1);
	await input.press("ArrowUp");
	await expect(chips.nth(0)).toHaveClass(/selected/);
});

for (const docked of [false, true]) {
 test(`compact command bar preserves controls and execution (docked=${docked})`, async ({ page }) => {
  const world = initialWorld();
  if (docked) {
   world.tabsBySpace[SPACE_1].push(tab("tab-empty-compact", SPACE_1, { url: "", title: "" }));
   world.treeItemsBySpace[SPACE_1].push(treeItem("tab-empty-compact", SPACE_1, 5));
   world.activeTabBySpace[SPACE_1] = "tab-empty-compact";
  }
  await bootChrome(page, world);
  await page.evaluate((isDocked) => {
   window.__lilo!.receive({ event: "settingsLoaded", settings: { commandBarLayout: "compact" } });
   if (!isDocked) window.__lilo!.receive({ event: "openCommandBar" });
  }, docked);
  const bar = page.locator(".command-bar");
  await expect(bar).toHaveClass(/compact/);
  await expect(page.locator(".command-bar-backdrop")).toHaveClass(docked ? /docked/ : /command-bar-backdrop/);
  await expect(page.locator(".command-bar-scopes")).toBeHidden();
  await expect(page.locator(".command-bar-footer")).toBeHidden();
  await expect.poll(async () => (await bar.boundingBox())?.height).toBe(320);
  const bounds = await bar.boundingBox();
  const input = page.locator(".command-bar-input");
  await input.press("Tab");
  // The info button is also reachable directly by its accessible name.
  const info = page.getByRole("button", { name: "Show keyboard hints" });
  await expect(info).toBeFocused();
  await info.press("Enter");
  await expect(info).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator(".command-bar-scopes")).toBeHidden();
  await expect(page.locator(".command-bar-help")).toBeVisible();
  expect(await bar.boundingBox()).toEqual(bounds);
  await expect(page.locator(".command-bar-strip")).toHaveCount(0);
  await expect(info).toHaveAttribute("aria-expanded", "false", { timeout: 5000 });
  await expect(page.locator(".command-bar-scopes")).toBeHidden();
  await info.press("Enter");
  await info.press("Escape");
  await expect(info).toBeFocused();
  await expect(page.locator(".command-bar-scopes")).toBeHidden();
  const scopePicker = page.locator(".scope-picker");
  await scopePicker.click();
  const menu = page.getByRole("menu", { name: "All", exact: true });
  await expect(menu).toBeVisible();
  await page.getByRole("menuitemradio", { name: "Tabs", exact: true }).click();
  await expect(scopePicker).toHaveAccessibleName("Tabs");
  await expect(input).toBeFocused();
  expect(await bar.boundingBox()).toEqual(bounds);
  await expect(page.locator(".scope-token")).toHaveCount(0);
  await input.press("Escape");
  await expect(scopePicker).toHaveAccessibleName("All");
  await expect(input).toBeFocused();
  await scopePicker.click();
  await page.getByRole("menuitemradio", { name: "Tabs", exact: true }).click();
  await input.fill("beta");
  expect(await bar.boundingBox()).toEqual(bounds);
  await expect(page.locator(".command-bar-result.selected")).toContainText("Beta Mail");
  await input.press("Enter");
  await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "switchTab" && c.payload.id === "tab-beta")).toBe(true);
 });
}


test("compact scope menu mouse selections keep the floating command bar open", async ({ page }) => {
 await bootChrome(page, initialWorld());
 await page.evaluate(() => {
  window.__lilo!.receive({ event: "settingsLoaded", settings: { commandBarLayout: "compact" } });
  window.__lilo!.receive({ event: "openCommandBar" });
 });
 const bar = page.locator(".command-bar");
 const picker = page.locator(".scope-picker");
 for (const name of ["Bookmarks", "Tabs", "Actions", "History", "Terminal", "Archived", "All"]) {
  await picker.click();
  await page.getByRole("menuitemradio", { name, exact: true }).click();
  await expect(bar).toBeVisible();
  await expect(picker).toHaveAccessibleName(name);
  await expect(page.locator(".command-bar-input")).toBeFocused();
 }
 await page.getByRole("button", { name: "Show keyboard hints" }).click();
 await page.locator(".command-bar-help").click({ position: { x: 8, y: 8 } });
 await expect(bar).toBeVisible();
 const backdrop = await page.locator(".command-bar-backdrop").boundingBox();
 await page.mouse.click(backdrop!.x + 4, backdrop!.y + 4);
 await expect(bar).toBeHidden();
});


for (const layout of ["default", "compact"]) {
 test(`new-tab overlay defers creation until submission (${layout})`, async ({ page }) => {
  await bootChrome(page, initialWorld());
  await page.evaluate((commandBarLayout) => {
   window.__lilo!.receive({ event: "settingsLoaded", settings: { commandBarLayout } });
   window.__lilo!.receive({ event: "openCommandBar", createOnSubmit: true });
  }, layout);
  const bar = page.locator(".command-bar");
  const input = page.locator(".command-bar-input");
  await expect(bar).toBeVisible();
  const mutations = async () => (await sentCommands(page)).filter((command) => ["createTab", "navigate", "closeTab"].includes(command.action));
  expect(await mutations()).toEqual([]);
  await input.press("Escape");
  await expect(bar).toBeHidden();
  expect(await mutations()).toEqual([]);
  await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar", createOnSubmit: true }));
  await input.fill("https://destination.example/new");
  await input.press("Enter");
  await expect(bar).toBeHidden();
  await expect.poll(async () => (await mutations()).map((command) => command.action)).toEqual(["createTab"]);
  expect((await mutations())[0].payload.url).toBe("https://destination.example/new");
 });
}


for (const layout of ["default", "compact"]) {
 test(`destination labels and dismissal focus reflect the opening intent (${layout})`, async ({ page }) => {
  await bootChrome(page, initialWorld());
  await page.evaluate((commandBarLayout) => {
   window.__lilo!.receive({ event: "settingsLoaded", settings: { commandBarLayout } });
   window.__lilo!.receive({ event: "openCommandBar", createOnSubmit: true });
  }, layout);
  const input = page.locator(".command-bar-input");
  const bar = page.locator(".command-bar");
  const hint = page.locator(layout === "compact" ? ".command-bar-result.selected .result-action-label" : ".key-hint-default > span");
  const focusRequests = async () => (await sentCommands(page)).filter((command) => command.action === "focusPage").length;
  await input.fill("https://destination.example/new");
  await expect(hint).toHaveText("Open in New Tab");
  await input.press("Escape");
  await expect(bar).toBeHidden();
  await expect.poll(focusRequests).toBe(1);
  await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
  await input.fill("https://destination.example/new");
  await expect(hint).toHaveText("Open");
  const backdrop = await page.locator(".command-bar-backdrop").boundingBox();
  await page.mouse.click(backdrop!.x + 4, backdrop!.y + 4);
  await expect(bar).toBeHidden();
  await expect.poll(focusRequests).toBe(2);
  await page.evaluate(() => {
   const button = document.createElement("button");
   button.textContent = "Focus target";
   button.style.cssText = "position:fixed;left:4px;top:4px;z-index:100001;pointer-events:auto";
   document.body.appendChild(button);
   window.__lilo!.receive({ event: "openCommandBar", createOnSubmit: true });
  });
  const target = page.getByRole("button", { name: "Focus target", exact: true });
  await target.click();
  await expect(bar).toBeHidden();
  await expect(target).toBeFocused();
  expect(await focusRequests()).toBe(2);
 });
}


for (const layout of ["default", "compact"]) {
 test(`empty web-related scopes offer an explicit web search (${layout})`, async ({ page }) => {
  await bootChrome(page, initialWorld());
  await page.evaluate((commandBarLayout) => window.__lilo!.receive({ event: "settingsLoaded", settings: { commandBarLayout } }), layout);
  const input = page.locator(".command-bar-input");
  for (const prefix of ["@", "#", "/"]) {
   await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar", createOnSubmit: true }));
   await input.fill(`${prefix} unlikely-test-query-987`);
   await page.evaluate(() => window.__lilo!.receive({ event: "historyResults", query: "unlikely-test-query-987", results: [] }));
   await page.getByRole("button", { name: "Search the Web", exact: true }).click();
   await expect(page.locator(".command-bar")).toBeHidden();
   const command = (await sentCommands(page)).filter((entry) => entry.action === "createTab").at(-1);
   expect(command?.payload.url).toContain("unlikely-test-query-987");
   expect((await sentCommands(page)).some((entry) => entry.action === "navigate")).toBe(false);
  }
  for (const prefix of [":", "<", ">"]) {
   await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar", createOnSubmit: true }));
   await input.fill(`${prefix} unlikely-test-query-987`);
   await expect(page.getByRole("button", { name: "Search the Web", exact: true })).toHaveCount(0);
  }
 });

 for (const constrainedContainer of [false, true]) {
  test(`long destinations and larger text fit constrained layouts (${layout}, container=${constrainedContainer})`, async ({ page }) => {
   await page.setViewportSize({ width: constrainedContainer ? 820 : 390, height: 480 });
   await page.emulateMedia({ reducedMotion: "reduce" });
   const world = initialWorld();
   world.sidebarVisible = false;
   await bootChrome(page, world);
   await page.evaluate(({ commandBarLayout, constrain }) => {
    if (constrain) document.documentElement.style.setProperty("--chrome-content-left", "450px");
    window.__lilo!.receive({ event: "settingsLoaded", settings: { commandBarLayout } });
    window.__lilo!.receive({ event: "openCommandBar", createOnSubmit: true });
   }, { commandBarLayout: layout, constrain: constrainedContainer });
   await page.addStyleTag({ content: ".command-bar { --font-size-md: 20px; --font-size-sm: 18px; }" });
   const input = page.locator(".command-bar-input");
   await input.fill("https://destination.example/" + "long-path/".repeat(24));
   const bar = page.locator(".command-bar");
   const row = page.locator(".command-bar-result.selected");
   await expect(row).toBeVisible();
   const bounds = (await bar.boundingBox())!;
   expect(bounds.x).toBeGreaterThanOrEqual(0);
   expect(bounds.x + bounds.width).toBeLessThanOrEqual(page.viewportSize()!.width);
   expect(bounds.y + bounds.height).toBeLessThanOrEqual(page.viewportSize()!.height);
   const sizes = await page.locator(".command-bar-results").evaluate((el) => ({ content: el.scrollWidth, visible: el.clientWidth }));
   expect(sizes.content).toBeLessThanOrEqual(sizes.visible + 1);
   const title = (await row.locator(".result-title").boundingBox())!;
   const subtitle = (await row.locator(".result-subtitle").boundingBox())!;
   expect(title.width).toBeGreaterThan(0);
   expect(subtitle.y).toBeGreaterThanOrEqual(title.y + title.height - 1);
   await expect(row.locator(".result-subtitle")).toHaveAttribute("title", /long-path/);
   await page.evaluate(() => document.documentElement.classList.add("reduced-transparency"));
   await expect(bar).toHaveCSS("backdrop-filter", "none");
  });
 }
}
