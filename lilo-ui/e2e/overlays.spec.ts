import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("command bar opens, searches, and closes on Escape", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await expect(page.locator(".command-bar")).toBeVisible();

	// Search for a non-active tab: the switcher excludes the active one from results.
	await page.locator(".command-bar-input").pressSequentially("beta");
	await expect(
		page.locator(".command-bar-result", { hasText: "Beta Mail" }),
	).toBeVisible();

	await page.keyboard.press("Escape");
	await expect(page.locator(".command-bar")).toHaveCount(0);
});

test("settings shell opens with sections and closes back to the app", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
	// Section nav (sidebar panel) and the active section's content both render.
	await expect(page.locator(".section-nav-button").nth(2)).toBeVisible();
	await expect(page.locator(".settings-section-content")).toBeVisible();
	await expect(page.locator(".sidebar-layout")).toHaveClass(/pushed/);

	// Search filters the sections, Escape clears it, and a second Escape closes the shell.
	await page.locator(".section-nav-toolbar input").fill("zoom");
	await expect(page.locator(".section-nav-count").first()).toBeVisible();
	await page.keyboard.press("Escape");
	await expect(page.locator(".section-nav-count")).toHaveCount(0);
	await page.keyboard.press("Escape");
	await expect(page.locator(".ui-shell-frame")).toHaveCount(0);
	await expect(page.locator(".sidebar-layout")).not.toHaveClass(/pushed/);
});
