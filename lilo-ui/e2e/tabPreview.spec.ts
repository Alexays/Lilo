import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const TINY_IMAGE =
	"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

test("hovering a tab row requests a preview and shows the card on reply", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await page.locator('[data-tab-id="tab-beta"]').hover();

	// The request goes out only after the hover delay.
	await expect
		.poll(async () =>
			(await sentCommands(page)).find((c) => c.action === "requestTabPreview")
				?.payload,
		)
		.toEqual({ tabId: "tab-beta" });

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		{ event: "tabPreviewReady", tabId: "tab-beta", image: TINY_IMAGE },
	);

	const card = page.locator(".tab-preview-card");
	await expect(card).toBeVisible();
	await expect(card).toContainText("Beta Mail");

	// Leaving the row hides the card instantly.
	await page.mouse.move(640, 500);
	await expect(card).toHaveCount(0);
});

test("a reply without an image shows nothing", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.locator('[data-tab-id="tab-gamma"]').hover();
	await expect
		.poll(async () =>
			(await sentCommands(page)).find((c) => c.action === "requestTabPreview")
				?.payload,
		)
		.toEqual({ tabId: "tab-gamma" });

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		{ event: "tabPreviewReady", tabId: "tab-gamma" },
	);

	await expect(page.locator(".tab-preview-card")).toHaveCount(0);
});
