import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const sizes = { event: "browsingDataSizesLoaded", history: 24_000_000, cookies: 2_000_000, cache: 400_000_000, storage: 180_000_000, historyEntries: 3214 };

test("Clear Browsing Data is a modal over Settings that clears, then closes once measured again", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openClearBrowsingData" }));
	const modal = page.getByRole("dialog", { name: "Clear Browsing Data" });
	await expect(modal).toBeVisible();
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
	await page.evaluate((message) => window.__lilo!.receive(message), sizes);
	await expect(modal).toContainText("will be freed");

	await modal.getByRole("radio", { name: "Last hour" }).click();
	await page.keyboard.press("Meta+Enter");
	const clear = (await sentCommands(page)).find((command) => command.action === "clearBrowsingData");
	expect(clear?.payload).toEqual({ kinds: ["history", "cache"], range: "hour" });

	await page.evaluate((message) => window.__lilo!.receive(message), sizes);
	await expect(modal).toHaveCount(0);
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
});

test("Escape cancels Clear Browsing Data and leaves Settings open", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openClearBrowsingData" }));
	const modal = page.getByRole("dialog", { name: "Clear Browsing Data" });
	await expect(modal.getByRole("button", { name: "Cancel" })).toBeFocused();

	await page.keyboard.press("Escape");

	await expect(modal).toHaveCount(0);
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
	expect((await sentCommands(page)).some((command) => command.action === "clearBrowsingData")).toBe(false);
});
