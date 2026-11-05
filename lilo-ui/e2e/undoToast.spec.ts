import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

function tabClosed(title: string) {
	return { event: "tabClosedUndoable", title };
}

test("the toast shows on close and Reopen posts restoreClosedTab", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		tabClosed("Alpha Docs"),
	);

	const toast = page.locator(".undo-toast");
	await expect(toast).toBeVisible();
	await expect(toast).toContainText(/Alpha Docs/);

	await toast.getByRole("button", { name: "Reopen" }).click();

	await expect(toast).toHaveCount(0);
	const commands = await sentCommands(page);
	expect(commands.some((c) => c.action === "restoreClosedTab")).toBe(true);
});

test("a second close replaces the current toast", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		tabClosed("Alpha Docs"),
	);
	const toast = page.locator(".undo-toast");
	await expect(toast).toContainText(/Alpha Docs/);

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		tabClosed("Beta Mail"),
	);

	await expect(toast).toHaveCount(1);
	await expect(toast).toContainText(/Beta Mail/);
});

test("keyboard focus pauses the countdown ring along with the timer", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		tabClosed("Alpha Docs"),
	);
	const toast = page.locator(".undo-toast");
	await toast.getByRole("button").focus();

	await expect(toast.locator(".undo-ring .remaining")).toHaveCSS("animation-play-state", "paused");
});

test("the toast docks in the sidebar, and over the page once the sidebar is hidden", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.evaluate((msg) => window.__lilo!.receive(msg), tabClosed("Alpha Docs"));
	await expect(page.locator(".sidebar .undo-toast")).toBeVisible();
	await expect(page.locator(".undo-toast")).toHaveCount(1);

	await page.evaluate(() => window.__lilo!.receive({ event: "sidebarVisibilityChanged", visible: false, width: 260 }));
	await expect(page.locator(".undo-area .undo-toast")).toBeVisible();
	await expect(page.locator(".sidebar .undo-toast")).toHaveCount(0);
});
