import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import type { BridgeTabSnapshot } from "../src/lib/bridge/protocol";

const HOME = '[data-tab-id="tab-home"]';

async function bootWithHome(page: Page, overrides: Partial<BridgeTabSnapshot> = {}) {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].map((tab) =>
		tab.id === "tab-home" ? { ...tab, ...overrides } : tab,
	);
	await bootChrome(page, world);
}

async function renameCommands(page: Page) {
	return (await sentCommands(page)).filter((command) => command.action === "renameTab");
}

test("removing a pinned tab offers Undo, and Command Z outside a field takes it", async ({ page }) => {
	await bootWithHome(page, { isClosed: true });

	// Delete on the focused row, the keyboard twin of its close button.
	await page.locator(HOME).focus();
	await page.keyboard.press("Delete");

	await expect(page.locator(HOME)).toHaveCount(0);
	const toast = page.locator(".undo-toast");
	await expect(toast).toHaveAttribute("aria-label", /Pinned Home/);

	await page.locator("body").focus();
	await page.keyboard.press("Meta+z");

	await expect(page.locator(HOME)).toHaveCount(1);
	await expect(toast).toHaveCount(0);
	expect((await sentCommands(page)).some((command) => command.action === "restoreClosedTab")).toBe(true);
});

test("Command Z in a text field leaves the toast alone", async ({ page }) => {
	await bootWithHome(page, { isClosed: true });
	await page.locator(HOME).focus();
	await page.keyboard.press("Backspace");
	await expect(page.locator(".undo-toast")).toBeVisible();

	await page.evaluate(() => {
		const input = document.createElement("input");
		input.id = "probe";
		document.body.append(input);
		input.focus();
	});
	await page.keyboard.press("Meta+z");

	await expect(page.locator(".undo-toast")).toBeVisible();
	expect((await sentCommands(page)).some((command) => command.action === "restoreClosedTab")).toBe(false);
});

test("double-clicking a pinned tab's title renames it, and Return confirms", async ({ page }) => {
	await bootWithHome(page);

	await page.locator(`${HOME} .tab-title`).dblclick();
	const input = page.locator(`${HOME} .tab-title-input`);
	await expect(input).toBeFocused();
	await expect(input).toHaveValue("Pinned Home");

	await input.fill("Home base");
	await page.keyboard.press("Enter");

	await expect(input).toHaveCount(0);
	await expect(page.locator(`${HOME} .tab-title`)).toHaveText("Home base");
	expect((await renameCommands(page)).map((command) => command.payload)).toEqual([{ id: "tab-home", title: "Home base" }]);
});

async function openEditor(page: Page, homeURL = "https://example.com/tab-home") {
	await page.evaluate((url) => window.__lilo!.receive({ event: "beginTabEdit", id: "tab-home", homeURL: url }), homeURL);
	return page.locator(".pinned-list .saved-tab-editor");
}

async function homeURLCommands(page: Page) {
	return (await sentCommands(page)).filter((command) => command.action === "setTabHomeURL");
}

test("Edit from the menu puts the editor in the row's place, and Escape cancels", async ({ page }) => {
	await bootWithHome(page);

	const editor = await openEditor(page);
	await expect(page.locator(HOME)).toHaveCount(0);
	await expect(editor.getByRole("textbox", { name: "Tab name" })).toBeFocused();
	await expect(editor.getByRole("textbox", { name: "Address" })).toHaveValue("https://example.com/tab-home");
	await expect(editor.getByRole("button", { name: "Use Current Page" })).toHaveCount(0);
	await page.keyboard.type("Nope");
	await page.keyboard.press("Escape");

	await expect(editor).toHaveCount(0);
	await expect(page.locator(`${HOME} .tab-title`)).toHaveText("Pinned Home");
	expect(await renameCommands(page)).toEqual([]);
	expect(await homeURLCommands(page)).toEqual([]);
});

test("away from home, Use Current Page makes the page the tab is on its home", async ({ page }) => {
	await bootWithHome(page);

	const editor = await openEditor(page, "https://example.com/start");
	await editor.getByRole("button", { name: "Use Current Page" }).click();
	await expect(editor.getByRole("textbox", { name: "Address" })).toHaveValue("https://example.com/tab-home");
	await editor.getByRole("button", { name: "Save" }).click();

	await expect(editor).toHaveCount(0);
	expect(await renameCommands(page)).toEqual([]);
	expect((await homeURLCommands(page)).map((command) => command.payload)).toEqual([{ id: "tab-home", url: "https://example.com/tab-home" }]);
});

test("an address that is not one keeps the editor open and sends nothing", async ({ page }) => {
	await bootWithHome(page);

	const editor = await openEditor(page);
	await editor.getByRole("textbox", { name: "Address" }).fill("not an address");
	await expect(editor.getByRole("button", { name: "Save" })).toBeDisabled();
	await page.keyboard.press("Enter");

	await expect(editor).toBeVisible();
	expect(await homeURLCommands(page)).toEqual([]);
});

test("a click outside the editor cancels it", async ({ page }) => {
	await bootWithHome(page);

	const editor = await openEditor(page);
	await editor.getByRole("textbox", { name: "Tab name" }).fill("Elsewhere");
	await page.locator('[data-tab-id="tab-beta"]').click();

	await expect(editor).toHaveCount(0);
	expect(await renameCommands(page)).toEqual([]);
});

test("an empty name gives the page title back", async ({ page }) => {
	await bootWithHome(page, { customTitle: "Named" });
	await expect(page.locator(`${HOME} .tab-title`)).toHaveText("Named");

	await page.locator(`${HOME} .tab-title`).dblclick();
	await page.locator(`${HOME} .tab-title-input`).fill("");
	await page.keyboard.press("Enter");

	await expect(page.locator(`${HOME} .tab-title`)).toHaveText("Pinned Home");
	expect((await renameCommands(page)).map((command) => command.payload)).toEqual([{ id: "tab-home", title: "" }]);
});

test("away from its page, a pinned tab shows its name, a slash and the page, and its icon takes it home", async ({ page }) => {
	await bootWithHome(page, { customTitle: "Mail", homeTitle: "Inbox", title: "A shared file" });

	const title = page.locator(`${HOME} .tab-title`);
	await expect(title).toHaveText("Mail/A shared file");
	await expect(title.locator(".away-slash")).toBeVisible();

	await page.locator(`${HOME} .tab-icon`).click();

	expect((await sentCommands(page)).some((command) => command.action === "returnTabHome" && command.payload.id === "tab-home")).toBe(true);
});
