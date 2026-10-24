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

test("Rename from the menu opens the editor, and Escape cancels", async ({ page }) => {
	await bootWithHome(page);

	await page.evaluate(() => window.__lilo!.receive({ event: "beginTabRename", id: "tab-home" }));
	const input = page.locator(`${HOME} .tab-title-input`);
	await expect(input).toBeFocused();
	await page.keyboard.type("Nope");
	await page.keyboard.press("Escape");

	await expect(input).toHaveCount(0);
	await expect(page.locator(`${HOME} .tab-title`)).toHaveText("Pinned Home");
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
