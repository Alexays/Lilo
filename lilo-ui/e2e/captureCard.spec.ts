import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const THUMB = `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500"><rect width="800" height="500" fill="#ddd"/></svg>')}`;

function copied(page: Page, captureId: string): Promise<void> {
	return page.evaluate(
		({ captureId, thumbURL }) =>
			window.__lilo!.receive({ event: "captureCopied", captureId, thumbURL, filename: `${captureId}.png` }),
		{ captureId, thumbURL: THUMB },
	);
}

async function commands(page: Page, action: string): Promise<unknown[]> {
	return (await sentCommands(page)).filter((command) => command.action === action).map((command) => command.payload);
}

const card = (page: Page) => page.locator(".capture-card");

test("a copied capture shows a card over the page, announced, and leaves the sidebar alone", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await copied(page, "c1");

	await expect(card(page)).toBeVisible();
	await expect(card(page).locator("img")).toHaveAttribute("src", THUMB);
	await expect(card(page)).toContainText("Copied");
	await expect(page.getByRole("status").filter({ hasText: "Screenshot copied" })).toHaveCount(1);
	await expect(page.locator(".sidebar .capture-card")).toHaveCount(0);
});

test("the card's click zone follows it in once it has flown in", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await expect(card(page)).toBeVisible();
	await page.waitForFunction(() => document.querySelector(".capture-card")!.getAnimations().length === 0);

	const box = await card(page).evaluate((el) => {
		const { x, y, width, height } = el.getBoundingClientRect();
		return { x, y, width, height };
	});
	await expect
		.poll(async () => {
			const zones = (await commands(page, "registerInteractiveZones")).flatMap(
				(payload) => (payload as { zones: { id: string; x: number; y: number; width: number; height: number }[] }).zones,
			);
			const zone = zones.filter((z) => z.id === "capture-card").at(-1);
			return zone && Math.abs(zone.x - box.x) < 1 && Math.abs(zone.y - box.y) < 1 && Math.abs(zone.width - box.width) < 1;
		})
		.toBe(true);
});

test("the card goes after 6 s, holds while hovered, and releases its capture", async ({ page }) => {
	await page.clock.install();
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await expect(card(page)).toBeVisible();
	await page.waitForFunction(() => document.querySelector(".capture-card")!.getAnimations().length === 0);

	await page.clock.runFor(4000);
	await card(page).hover();
	await page.clock.runFor(10_000);
	await expect(card(page)).toBeVisible();

	await page.mouse.move(5, 5);
	await page.clock.runFor(1500);
	await expect(card(page)).toBeVisible();
	await page.clock.runFor(600);
	await expect(card(page)).toHaveCount(0);
	expect(await commands(page, "releaseCapture")).toEqual([{ captureId: "c1" }]);
});

test("Edit opens the capture in the editor and keeps it held", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await card(page).getByRole("button", { name: "Edit", exact: true }).click();

	await expect(card(page)).toHaveCount(0);
	expect(await commands(page, "editCapture")).toEqual([{ captureId: "c1" }]);
	expect(await commands(page, "releaseCapture")).toEqual([]);
});

test("clicking the thumbnail opens the capture in the editor", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await card(page).locator(".thumb").click();

	await expect(card(page)).toHaveCount(0);
	expect(await commands(page, "editCapture")).toEqual([{ captureId: "c1" }]);
});

test("Save writes the capture to the default location, then releases it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await card(page).getByRole("button", { name: "Save", exact: true }).click();

	await expect(card(page)).toHaveCount(0);
	const sent = (await sentCommands(page)).map((command) => command.action);
	expect(sent.filter((action) => action === "screenshot.saveDefault" || action === "releaseCapture")).toEqual([
		"screenshot.saveDefault",
		"releaseCapture",
	]);
	expect(await commands(page, "screenshot.saveDefault")).toEqual([{ id: "c1", filename: "c1.png" }]);
});

test("the dismiss button and Escape release the capture", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await card(page).getByRole("button", { name: "Dismiss" }).click();
	await expect(card(page)).toHaveCount(0);

	await copied(page, "c2");
	await card(page).getByRole("button", { name: "Edit", exact: true }).focus();
	await page.keyboard.press("Escape");
	await expect(card(page)).toHaveCount(0);
	expect(await commands(page, "releaseCapture")).toEqual([{ captureId: "c1" }, { captureId: "c2" }]);
});

test("swiping the card to the right dismisses it, a short swipe springs back", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await expect(card(page)).toBeVisible();
	await page.waitForFunction(() => document.querySelector(".capture-card")!.getAnimations().length === 0);
	const box = (await card(page).locator(".thumb").boundingBox())!;
	const swipe = async (distance: number) => {
		await page.mouse.move(box.x + 40, box.y + 30);
		await page.mouse.down();
		await page.mouse.move(box.x + 40 + distance, box.y + 32, { steps: 8 });
		await page.mouse.up();
	};

	await swipe(20);
	await expect(card(page)).toBeVisible();
	await expect.poll(() => card(page).evaluate((el) => getComputedStyle(el).transform)).toMatch(/^(none|matrix\(1, 0, 0, 1, 0, 0\))$/);

	await swipe(90);
	await expect(card(page)).toHaveCount(0);
	expect(await commands(page, "releaseCapture")).toEqual([{ captureId: "c1" }]);
	expect(await commands(page, "editCapture")).toEqual([]);
});

test("the card's actions are reachable from the keyboard", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await card(page).locator(".thumb").focus();
	await page.keyboard.press("Tab");
	await expect(card(page).getByRole("button", { name: "Edit", exact: true })).toBeFocused();
	await page.keyboard.press("Tab");
	await page.keyboard.press("Tab");
	await expect(card(page).getByRole("button", { name: "Dismiss" })).toBeFocused();
	await page.keyboard.press("Enter");
	await expect(card(page)).toHaveCount(0);
});

test("a new capture replaces the card", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await copied(page, "c1");
	await copied(page, "c2");

	await expect(card(page)).toHaveCount(1);
	expect(await commands(page, "releaseCapture")).toEqual([{ captureId: "c1" }]);
	await card(page).getByRole("button", { name: "Edit", exact: true }).click();
	expect(await commands(page, "editCapture")).toEqual([{ captureId: "c2" }]);
});

test("the card slides in, and only fades with reduced motion", async ({ page }) => {
	// Read within a frame of the capture, while the card's entrance still runs.
	const entrance = (captureId: string) =>
		page.evaluate(async ({ captureId, thumbURL }) => {
			window.__lilo!.receive({ event: "captureCopied", captureId, thumbURL, filename: `${captureId}.png` });
			await new Promise(requestAnimationFrame);
			return document.querySelector(".capture-card")!.getAnimations()
				.flatMap((animation) => (animation.effect as KeyframeEffect).getKeyframes())
				.map((frame) => ({ transform: String(frame.transform ?? ""), opacity: String(frame.opacity ?? "") }));
		}, { captureId, thumbURL: THUMB });
	await bootChrome(page, initialWorld());
	await page.locator(".capture-host").waitFor({ state: "attached" });
	const sliding = await entrance("c1");
	expect(sliding.some((frame) => frame.transform.includes("translate"))).toBe(true);

	await page.emulateMedia({ reducedMotion: "reduce" });
	await card(page).getByRole("button", { name: "Dismiss" }).click();
	await expect(card(page)).toHaveCount(0);
	const fading = await entrance("c2");
	expect(fading.length).toBeGreaterThan(0);
	expect(fading.some((frame) => frame.transform.includes("translate"))).toBe(false);
});

for (const size of [
	{ width: 600, height: 400 },
	{ width: 1600, height: 1000 },
]) {
	test(`the card sits in the page area's bottom-right corner at ${size.width}x${size.height}`, async ({ page }) => {
		await page.setViewportSize(size);
		await page.emulateMedia({ reducedMotion: "reduce" });
		await bootChrome(page, initialWorld());
		await copied(page, "c1");
		await expect(card(page)).toBeVisible();
		await page.waitForFunction(() => document.querySelector(".capture-card")!.getAnimations().length === 0);

		const box = (await card(page).boundingBox())!;
		const sidebar = (await page.locator(".sidebar").boundingBox())!;
		const content = await page.evaluate(() => {
			const root = document.querySelector(".capture-host")!.getBoundingClientRect();
			return { left: root.left, right: root.right, top: root.top, bottom: root.bottom };
		});
		expect(box.x).toBeGreaterThanOrEqual(sidebar.x + sidebar.width);
		expect(box.x).toBeGreaterThanOrEqual(content.left);
		expect(box.y).toBeGreaterThanOrEqual(content.top);
		expect(box.x + box.width).toBeLessThanOrEqual(content.right);
		expect(box.y + box.height).toBeLessThanOrEqual(content.bottom);
		expect(content.right - (box.x + box.width)).toBeLessThan(24);
		expect(content.bottom - (box.y + box.height)).toBeLessThan(24);
		for (const button of await card(page).getByRole("button").all()) {
			const b = (await button.boundingBox())!;
			expect(b.x + b.width).toBeLessThanOrEqual(box.x + box.width);
		}
	});
}

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("the card speaks French", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await copied(page, "c1");

		await expect(card(page)).toContainText("Copiée");
		await expect(card(page).getByRole("button", { name: "Modifier", exact: true })).toBeVisible();
		await expect(card(page).getByRole("button", { name: "Enregistrer", exact: true })).toBeVisible();
		await expect(card(page).getByRole("button", { name: "Ignorer" })).toBeVisible();
		await expect(card(page).getByRole("button", { name: "Modifier la capture" })).toBeVisible();
		await expect(page.getByRole("status").filter({ hasText: "Capture copiée" })).toHaveCount(1);
	});
});
