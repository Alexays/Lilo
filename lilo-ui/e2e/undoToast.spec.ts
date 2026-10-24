import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

function tabClosed(title: string) {
	return { event: "tabClosedUndoable", title };
}

test("the toast shows on close and Undo posts restoreClosedTab", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		tabClosed("Alpha Docs"),
	);

	const toast = page.locator(".undo-toast");
	await expect(toast).toBeVisible();
	await expect(toast).toHaveAttribute("aria-label", /Alpha Docs/);

	await toast.click();

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
	await expect(toast).toHaveAttribute("aria-label", /Alpha Docs/);

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		tabClosed("Beta Mail"),
	);

	await expect(toast).toHaveCount(1);
	await expect(toast).toHaveAttribute("aria-label", /Beta Mail/);
});

test("keyboard focus pauses the countdown ring along with the timer", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		tabClosed("Alpha Docs"),
	);
	const toast = page.locator(".undo-toast");
	await toast.focus();

	await expect(toast.locator(".undo-ring circle")).toHaveCSS("animation-play-state", "paused");
});
