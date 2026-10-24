import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const now = Date.now();
const rows = [
	{ id: "tab-alpha", title: "Alpha Docs", spaceName: "Work", leftAt: 0 },
	{ id: "tab-zeta", title: "Zeta Chat", spaceName: "Play", leftAt: now - 2 * 60_000 },
	{ id: "tab-beta", title: "Beta Mail", spaceName: "Work", leftAt: now - 3 * 3_600_000 },
	{ id: "tab-shell", title: "zsh", spaceName: "Work", leftAt: now - 60_000, kind: "terminal", cwd: "/Users/me/lilo" },
].map((row) => ({
	url: `https://${row.id}.example`,
	faviconDataURL: "",
	kind: "web",
	cwd: "",
	terminalState: "",
	terminalCommand: "",
	...row,
}));

function send(page: Page, message: Record<string, unknown>): Promise<void> {
	return page.evaluate((msg) => window.__lilo!.receive(msg), message);
}

const open = (page: Page, selected = 1) => send(page, { event: "tabSwitcherOpened", tabs: rows, selected });
const move = (page: Page, by: number) => send(page, { event: "tabSwitcherMoved", by });
const close = (page: Page, commit: boolean) => send(page, { event: "tabSwitcherClosed", commit });

async function switchedTo(page: Page): Promise<string[]> {
	return (await sentCommands(page))
		.filter((command) => command.action === "switchToRecentTab")
		.map((command) => String(command.payload.id));
}

test("the switcher lists recent tabs, previous one selected, with their Space and age", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await open(page);

	const list = page.getByRole("listbox", { name: "Recent tabs" });
	await expect(list).toBeVisible();
	const options = list.getByRole("option");
	await expect(options).toHaveCount(4);
	await expect(options.nth(0)).toContainText("Work · current");
	await expect(options.nth(1)).toContainText("Play · 2 min ago");
	await expect(options.nth(2)).toContainText("Work · 3 h ago");
	await expect(options.nth(3)).toContainText("lilo");
	await expect(options.nth(3)).toContainText("Work · terminal");
	await expect(options.nth(1)).toHaveAttribute("aria-selected", "true");
	await expect(page.locator(".tab-switcher-live")).toHaveText("Zeta Chat, Play · 2 min ago");
	await expect(page.getByText("Release Control to open")).toBeVisible();
});

test("Tab moves down and Shift-Tab up, both wrapping, and the release opens the selection", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await open(page);
	const options = page.getByRole("option");
	await expect(options.nth(1)).toHaveAttribute("aria-selected", "true");

	await move(page, 1);
	await move(page, 1);
	await expect(options.nth(3)).toHaveAttribute("aria-selected", "true");
	await move(page, 1);
	await expect(options.nth(0)).toHaveAttribute("aria-selected", "true");
	await move(page, -1);
	await expect(options.nth(3)).toHaveAttribute("aria-selected", "true");
	await move(page, -1);
	await close(page, true);

	await expect(page.getByRole("listbox")).toHaveCount(0);
	expect(await switchedTo(page)).toEqual(["tab-beta"]);
});

test("Escape closes the switcher without switching", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await open(page);
	await expect(page.getByRole("listbox")).toBeVisible();

	await close(page, false);

	await expect(page.getByRole("listbox")).toHaveCount(0);
	expect(await switchedTo(page)).toEqual([]);
});

test("a quick tap switches to the previous tab without ever showing the panel", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate((tabs) => {
		new MutationObserver(() => {
			if (document.querySelector(".tab-switcher")) document.body.dataset.switcherShown = "true";
		}).observe(document.body, { childList: true, subtree: true });
		window.__lilo!.receive({ event: "tabSwitcherOpened", tabs, selected: 1 });
		window.__lilo!.receive({ event: "tabSwitcherClosed", commit: true });
	}, rows);

	await expect.poll(() => switchedTo(page)).toEqual(["tab-zeta"]);
	await page.waitForTimeout(300);
	await expect(page.locator("body")).not.toHaveAttribute("data-switcher-shown", "true");
});

test("hovering a row selects it and clicking one opens it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await open(page);
	const options = page.getByRole("option");

	await options.nth(2).hover({ position: { x: 20, y: 10 } });
	await options.nth(2).hover({ position: { x: 40, y: 12 } });
	await expect(options.nth(2)).toHaveAttribute("aria-selected", "true");
	await options.nth(3).click();

	await expect(page.getByRole("listbox")).toHaveCount(0);
	expect(await switchedTo(page)).toEqual(["tab-shell"]);
	await close(page, true);
	expect(await switchedTo(page)).toEqual(["tab-shell"]);
});

test("a panel opening under a resting pointer keeps the keyboard's selection", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await open(page);
	const box = await page.getByRole("option").nth(2).boundingBox();
	await close(page, false);
	await page.mouse.move(box!.x + 20, box!.y + 10);

	await open(page);
	await page.waitForTimeout(100);

	await expect(page.getByRole("option").nth(1)).toHaveAttribute("aria-selected", "true");
});

test("Settings sets the order Control-Tab walks tabs in", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await send(page, { event: "openSettings" });
	await page.locator(".ui-link-row").filter({ hasText: "Keyboard shortcuts" }).click();
	await send(page, { event: "shortcutsLoaded", groups: [], controlTabOrder: "recent" });

	const order = page.getByRole("radiogroup", { name: "Control-Tab switches tabs in" });
	await expect(order.getByRole("radio", { name: "Recent order" })).toHaveAttribute("aria-checked", "true");
	await order.getByRole("radio", { name: "Sidebar order" }).click();

	const commands = (await sentCommands(page)).filter((command) => command.action === "setControlTabOrder");
	expect(commands.map((command) => command.payload)).toEqual([{ order: "sidebar" }]);
	await send(page, { event: "shortcutsLoaded", groups: [], controlTabOrder: "sidebar" });
	await expect(order.getByRole("radio", { name: "Sidebar order" })).toHaveAttribute("aria-checked", "true");
});
