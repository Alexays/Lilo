import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("the address bar hides the URL of a selected tab whose folder is locked", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const urlBar = page.locator(".url-display");
	await expect(urlBar).toContainText("example.com");

	await page.evaluate(() =>
		window.__lilo!.receive({ event: "contentPlaceholder", tabId: "tab-alpha", lockedFolderId: "folder-vault" }),
	);

	await expect(urlBar).not.toContainText("example.com");
});
