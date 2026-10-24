import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

function startDownload(page: Page): Promise<void> {
	return page.evaluate(() => window.__lilo!.receive({
		event: "downloadUpdated",
		id: 1, url: "https://example.com/a.zip", filename: "a.zip", bytesReceived: 0, totalBytes: 10,
		state: "inProgress", startedAt: Date.now(), fileMissing: false, source: "wk",
	}));
}

test("a panel takes the focus when it opens and hands it back to its button when it closes", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await startDownload(page);
	const button = page.getByRole("button", { name: /^Downloads/ });
	await button.click();

	const panel = page.getByRole("dialog", { name: "Downloads" });
	await expect(panel).toBeVisible();
	await expect.poll(() => panel.evaluate((el) => el.contains(document.activeElement))).toBe(true);

	await page.keyboard.press("Escape");
	await expect(panel).toHaveCount(0);
	await expect(button).toBeFocused();
});

test("Escape closes the command bar over a panel, not the panel", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openDownloads" }));
	await expect(page.getByRole("dialog", { name: "Downloads" })).toBeVisible();
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await expect(page.locator(".command-bar")).toBeVisible();

	await page.keyboard.press("Escape");

	await expect(page.locator(".command-bar")).toBeHidden();
	await expect(page.getByRole("dialog", { name: "Downloads" })).toBeVisible();
});

test("Return on the delete confirmation's focused Keep button keeps the space", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate((id) => window.__lilo!.receive({ event: "openSpaceEditor", id }), SPACE_1);
	await page.locator(".editor-panel").getByRole("button", { name: "Delete" }).click();
	const keep = page.getByRole("button", { name: "Keep Space" });
	await expect(keep).toBeFocused();

	await page.keyboard.press("Enter");

	await expect(page.getByRole("dialog", { name: /Delete/ })).toBeHidden();
	await expect(page.locator(".editor-panel")).toBeVisible();
	expect((await sentCommands(page)).some((command) => command.action === "deleteSpace")).toBe(false);
});

test("Tab stays inside the delete confirmation", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate((id) => window.__lilo!.receive({ event: "openSpaceEditor", id }), SPACE_1);
	await page.locator(".editor-panel").getByRole("button", { name: "Delete" }).click();
	const keep = page.getByRole("button", { name: "Keep Space" });
	await expect(keep).toBeFocused();

	await page.keyboard.press("Tab");
	await expect(page.getByRole("button", { name: "Delete Space" })).toBeFocused();
	await page.keyboard.press("Tab");
	await expect(keep).toBeFocused();
	await page.keyboard.press("Shift+Tab");
	await expect(page.getByRole("button", { name: "Delete Space" })).toBeFocused();
});

test("the next onboarding step takes the focus from the button that led to it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "onboardingState", show: true, step: 2, usage: "browse" }));
	const card = page.locator(".card");
	const next = card.locator(".ob-foot .ob-btn").last();
	await next.focus();

	await page.keyboard.press("Enter");

	await expect(card).toHaveAttribute("aria-label", /.+/);
	await expect.poll(() => card.evaluate((el) => el.contains(document.activeElement) && document.activeElement !== document.body)).toBe(true);
});

test("Escape in the space editor closes it alone", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate((id) => window.__lilo!.receive({ event: "openSpaceEditor", id }), SPACE_1);
	const name = page.locator(".identity-name-input");
	await name.focus();

	const prevented = await page.evaluate(() => new Promise<boolean>((resolve) => {
		window.addEventListener("keydown", (event) => resolve(event.defaultPrevented), { once: true });
		document.activeElement!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
	}));

	expect(prevented).toBe(true);
	await expect(page.locator(".editor-panel")).toHaveCount(0);
});
