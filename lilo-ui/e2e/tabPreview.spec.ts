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

test("resting on a pinned tab glances at its live page, in a card that takes the pointer", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.locator('[data-tab-id="tab-home"]').hover();

	const card = page.locator(".tab-preview-card.glance");
	await expect(card).toBeVisible();
	await expect(card).toContainText("Pinned Home");
	const glances = async () => (await sentCommands(page)).filter((c) => c.action === "showTabGlance" || c.action === "hideTabGlance");
	expect(await glances()).toEqual([{ action: "showTabGlance", payload: { tabId: "tab-home" } }]);
	expect((await sentCommands(page)).some((c) => c.action === "requestTabPreview")).toBe(false);

	// The pointer crosses from the row to the card, whose page slot the host lays the tab's view over.
	await card.getByRole("button", { name: "Close" }).hover();
	await expect(card).toBeVisible();
	const slot = (await card.locator(".tab-glance-page").boundingBox())!;
	expect(slot.width).toBeGreaterThan(200);
	expect(slot.height).toBeGreaterThan(200);

	await card.getByRole("button", { name: "Close" }).click();
	await expect(card).toHaveCount(0);
	expect((await glances()).map((c) => c.action)).toEqual(["showTabGlance", "hideTabGlance"]);
});

test("dragging the glance card's corner resizes it and keeps the size", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.locator('[data-tab-id="tab-home"]').hover();
	const card = page.locator(".tab-preview-card.glance");
	const before = (await card.boundingBox())!;

	const corner = (await card.locator(".tab-glance-resize.xy").boundingBox())!;
	await page.mouse.move(corner.x + corner.width / 2, corner.y + corner.height / 2);
	await page.mouse.down();
	await page.mouse.move(corner.x + 100, corner.y + 80, { steps: 5 });
	await page.mouse.up();

	const after = (await card.boundingBox())!;
	expect(after.width).toBeGreaterThan(before.width + 50);
	expect(after.height).toBeGreaterThan(before.height + 50);
	const saved = (await sentCommands(page)).filter((c) => c.action === "setSetting").at(-1)?.payload;
	expect(saved).toEqual({ key: "tabGlanceSize", value: `${Math.round(after.width)}x${Math.round(after.height)}` });
});

test("with glance turned off, a pinned tab gets the snapshot card", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), settings: { tabGlance: "false" } });

	await page.locator('[data-tab-id="tab-home"]').hover();

	await expect
		.poll(async () => (await sentCommands(page)).find((c) => c.action === "requestTabPreview")?.payload)
		.toEqual({ tabId: "tab-home" });
	expect((await sentCommands(page)).some((c) => c.action === "showTabGlance")).toBe(false);
});

test("a pinned pill of a top strip glances under the strip", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), tabPosition: "top" }, ".tab-strip .strip-tab");

	const pill = page.locator('.tab-strip [data-tab-id="tab-home"]');
	await pill.hover();

	const card = page.locator(".tab-preview-card.glance");
	await expect(card).toBeVisible();
	const strip = (await page.locator(".tab-strip").boundingBox())!;
	expect((await card.boundingBox())!.y).toBeGreaterThanOrEqual(strip.y + strip.height);
	expect((await sentCommands(page)).filter((c) => c.action === "showTabGlance").map((c) => c.payload)).toEqual([{ tabId: "tab-home" }]);
});
