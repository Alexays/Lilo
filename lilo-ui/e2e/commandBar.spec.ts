import { expect, test, type Page } from "@playwright/test";
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
	const escHint = page.locator(".command-bar-footer > .footer-hint");
	await expect(escHint).toHaveText("EscClose");

	await input.fill("@beta");
	await expect(escHint).toHaveText("EscBack");
	await input.press("Meta+m");
	await expect(input).toHaveAttribute("placeholder", /Space/);
	await input.press("Escape");
	await expect(input).toHaveValue("@beta");
	await input.press("Escape");
	await expect(escHint).toHaveText("EscClose");
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
	await expect(selected.locator(".result-helper")).toHaveText("⌘T");
	await expect(page.locator(".command-bar-footer .footer-hint").first()).toHaveText("↩Run");
});

test("row shortcuts and footer keys spell keys with the same symbols", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");

	await input.fill(":sidebar");
	await expect(page.locator(".command-bar-result.selected .result-helper")).toHaveText("⇧⌘S");
	await input.fill(":terminal");
	await expect(page.locator(".command-bar-result", { hasText: "New Terminal" }).locator(".result-helper")).toHaveText("⌃`");

	await input.fill("beta");
	await expect(page.locator(".command-bar-footer kbd")).toHaveText(["↩", "⌘↩", "⌥↩", "⇧↩", "⌘C", "⌘⌫", "⌘M", "Esc"]);
});

test("scope chips are set in the footer hints' size", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const footerSize = await page.locator(".command-bar-footer .footer-hint").first().evaluate((el) => getComputedStyle(el).fontSize);

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
	expect(await row.locator(".result-main").evaluate((el) => el.clientWidth)).toBeGreaterThanOrEqual(180);
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
		const toolbar = (await page.locator(".command-bar-toolbar").boundingBox())!;

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
	await expect(page.locator(".command-bar-result.selected .result-helper")).toHaveText("⌥⌘L");
	await input.press("Enter");

	await expect(page.locator(".downloads-panel")).toBeVisible();
});

for (const [how, click] of [
	["a Command-click", { modifiers: ["Meta"] }],
	["a middle click", { button: "middle" }],
] as const) {
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
	const alpha = page.locator(".result-icon-favicon", { has: page.locator(`img[src^="data:image/png;base64,iVBOR"]`) }).first();
	await expect(alpha.locator(".result-favicon-fallback")).toBeHidden();
	const beta = page.locator(".result-icon-favicon", { has: page.locator('img[src="data:image/png;base64,broken"]') }).first();
	await expect(beta.locator(".result-favicon-fallback")).toBeVisible();
});
