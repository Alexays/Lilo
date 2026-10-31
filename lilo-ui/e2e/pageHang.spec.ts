import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

function responsiveness(page: Page, tabId: string, responsive: boolean): Promise<void> {
	return page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		{ event: "pageResponsivenessChanged", tabId, responsive, host: "example.com", site: "example.com" },
	);
}

test("a hung active tab shows the card and a sidebar counter, both gone once it answers", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await responsiveness(page, "tab-alpha", false);

	const card = page.locator(".page-hang .card");
	await expect(card).toBeVisible();
	await expect(card.locator("h1")).toHaveText("example.com isn't responding");
	await expect(page.locator('[data-tab-id="tab-alpha"] .hang-timer')).toHaveText(/\d+ s/);

	await responsiveness(page, "tab-alpha", true);

	await expect(card).toHaveCount(0);
	await expect(page.locator('[data-tab-id="tab-alpha"] .hang-timer')).toHaveCount(0);
});

test("a background tab hanging shows only in the sidebar", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await responsiveness(page, "tab-beta", false);

	await expect(page.locator('[data-tab-id="tab-beta"] .hang-timer')).toBeVisible();
	await expect(page.locator(".page-hang")).toHaveCount(0);
});

test("Wait hides the card, Reload asks the host to reload", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await responsiveness(page, "tab-alpha", false);
	const card = page.locator(".page-hang .card");

	await card.getByRole("button", { name: "Wait" }).click();
	await expect(card).toHaveCount(0);
	await expect(page.locator('[data-tab-id="tab-alpha"] .hang-timer')).toBeVisible();

	await responsiveness(page, "tab-alpha", true);
	await responsiveness(page, "tab-alpha", false);
	await card.getByRole("button", { name: "Reload" }).click();

	await expect(card).toHaveCount(0);
	const actions = (await sentCommands(page)).map((command) => command.action);
	expect(actions).toContain("reload");
});

test("hanging again after a reload offers reloading without the blocker", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await responsiveness(page, "tab-alpha", false);
	await page.locator(".page-hang .card").getByRole("button", { name: "Reload" }).click();
	await responsiveness(page, "tab-alpha", true);

	await responsiveness(page, "tab-alpha", false);

	const card = page.locator(".page-hang .card");
	await expect(card.locator("h1")).toHaveText("example.com froze again");
	await card.getByRole("button", { name: "Reload without blocker" }).click();
	await expect(page.locator(".undo-toast")).toBeVisible();
	// The host reloads the tab itself once the rules without the blocker are in place.
	const commands = (await sentCommands(page)).filter(
		(command) => command.action === "toggleBlockerAllowlist" || command.action === "reload",
	);
	expect(commands.map((command) => command.action)).toEqual(["reload", "toggleBlockerAllowlist"]);
	expect(commands[1].payload).toEqual({ host: "example.com", reloadTabId: "tab-alpha" });
});
