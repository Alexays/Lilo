import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

// The strip between the screenshot and copy buttons, as painted while the bar is hovered.
async function gapBetweenButtons(page: Page, url: string): Promise<Buffer> {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].find((tab) => tab.id === "tab-alpha")!.url = url;
	await bootChrome(page, world);
	await page.locator(".url-trigger").hover();
	// The spring passes its end value on the way: wait for the transitions to finish, not for a value.
	await expect(page.locator(".url-actions-reveal")).toHaveCSS("opacity", "1");
	await page.evaluate(() => Promise.all([".url-actions-reveal", ".url-text-shell"].flatMap((selector) => document.querySelector(selector)!.getAnimations().map((animation) => animation.finished))));
	const shot = (await page.locator(".url-screenshot-btn").boundingBox())!;
	const copy = (await page.locator(".url-copy-btn").boundingBox())!;
	return page.screenshot({ clip: { x: shot.x + shot.width, y: shot.y, width: copy.x - shot.x - shot.width, height: shot.height } });
}

test("the hovered bar's buttons hide the address under them", async ({ page }) => {
	const blank = await gapBetweenButtons(page, "https://a.io");
	const long = await gapBetweenButtons(page, "https://a-very-long-subdomain.with.many.labels.example-domain-name.co.uk/a/long/path");

	// Renders of the same background can differ by a shade; an address showing through differs by far more.
	const maxDifference = await page.evaluate(async (strips) => {
		const decoded = await Promise.all(
			strips.map(async (base64) => {
				const bitmap = await createImageBitmap(new Blob([Uint8Array.from(atob(base64), (char) => char.charCodeAt(0))], { type: "image/png" }));
				const context = new OffscreenCanvas(bitmap.width, bitmap.height).getContext("2d")!;
				context.drawImage(bitmap, 0, 0);
				return context.getImageData(0, 0, bitmap.width, bitmap.height).data;
			}),
		);
		return decoded[0].reduce((max, value, index) => Math.max(max, Math.abs(value - decoded[1][index])), 0);
	}, [blank.toString("base64"), long.toString("base64")]);
	expect(maxDifference).toBeLessThanOrEqual(2);
});

test("the details card gives way to the command bar opened over a resting pointer", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.locator(".url-trigger").hover();
	await page.mouse.move(60, 72);
	await expect(page.locator(".url-details")).toBeVisible();

	// Cmd+L with the pointer still on the address.
	await page.evaluate(() => window.__lilo!.receive({ event: "toggleCommandBar", selectAll: true }));
	await page.mouse.move(62, 73);

	await expect(page.locator(".command-bar")).toBeVisible();
	await expect(page.locator(".url-details")).toHaveCount(0);
});

test("the details card is wider than a narrow sidebar and shows while a request waits", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), sidebarWidth: 220 });
	await page.evaluate(() =>
		window.__lilo!.receive({
			event: "extensionPermissionRequested", requestId: "e1", extensionName: "Okta Verify", permissions: [], origins: ["https://example.okta.com"], type: "urls",
		}),
	);
	await expect(page.locator(".url-drawer-clip")).toContainText("Okta Verify");

	await page.locator(".url-trigger").hover();
	await page.mouse.move(60, 72);
	const card = page.locator(".url-details");
	await expect(card).toBeVisible();
	const box = (await card.boundingBox())!;
	expect(box.width).toBeGreaterThanOrEqual(300);
	const pastSidebar = await page.evaluate(([x, y]) => !!document.elementFromPoint(x, y)?.closest(".url-details"), [box.x + box.width - 8, box.y + 8]);
	expect(pastSidebar).toBe(true);
	await expect(card.locator("dd").first()).not.toHaveText(/\n/);
});

test("the bar's and find bar's buttons take the theme's focus ring", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].find((tab) => tab.id === "tab-alpha")!.isCameraActive = true;
	await bootChrome(page, world);
	await expect(async () => {
		await page.evaluate(() => window.__lilo!.receive({ event: "toggleFindBar", query: "x" }));
		await expect(page.locator(".find-bar")).toBeVisible({ timeout: 200 });
	}).toPass();
	// Opening the find bar focuses its input a frame later: let that land before focusing the buttons.
	await expect(page.locator(".find-input")).toBeFocused();
	await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
	const ring = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--focus-outline"));
	expect(ring).toContain("solid");

	for (const selector of [".permissions-btn", ".url-blocker-btn", ".url-screenshot-btn", ".url-copy-btn", ".find-bar .case-btn", ".find-bar .close-btn"]) {
		await page.keyboard.press("Shift");
		await page.locator(selector).focus();
		await expect(page.locator(selector), selector).toHaveCSS("outline-style", "solid");
	}
});

test("the address fades out under the buttons in step with their fade in", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.mouse.move(600, 400);
	await page.evaluate(() => {
		const shell = document.querySelector(".url-text-shell")!;
		const reveal = document.querySelector(".url-actions-reveal")!;
		const samples: Array<{ buttons: number; address: number }> = [];
		(window as unknown as { __fade: typeof samples }).__fade = samples;
		const sample = () => {
			samples.push({
				buttons: Number(getComputedStyle(reveal).opacity),
				address: 1 - Number(getComputedStyle(shell).getPropertyValue("--url-reveal-mask") || 0),
			});
			if (samples.length < 40) requestAnimationFrame(sample);
		};
		requestAnimationFrame(sample);
	});
	await page.locator(".url-trigger").hover();
	await page.waitForFunction(() => (window as unknown as { __fade: unknown[] }).__fade.length >= 40);

	const samples = await page.evaluate(() => (window as unknown as { __fade: Array<{ buttons: number; address: number }> }).__fade);
	const midway = samples.filter((s) => s.buttons > 0.1 && s.buttons < 0.9);
	expect(midway.length).toBeGreaterThan(2);
	for (const s of midway) expect(Math.abs(s.address - s.buttons)).toBeLessThanOrEqual(0.1);
	expect(samples.at(-1)).toEqual({ buttons: 1, address: 1 });
});

test("the screenshot menu opens under the bar, inside the sidebar", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.locator(".url-trigger").hover();
	await page.locator(".url-screenshot-btn").click();
	// The menu pops in with a scale: read its box once it has settled.
	await page.locator(".screenshot-menu").evaluate((el) => Promise.all(el.getAnimations().map((animation) => animation.finished)));

	const menu = (await page.locator(".screenshot-menu").boundingBox())!;
	const sidebar = (await page.locator(".sidebar").boundingBox())!;
	const bar = (await page.locator(".url-trigger").boundingBox())!;
	expect(menu.x).toBeGreaterThanOrEqual(sidebar.x);
	expect(menu.x + menu.width).toBeLessThanOrEqual(bar.x + bar.width + 0.5);
	expect(menu.y).toBeGreaterThanOrEqual(bar.y + bar.height);
});

for (const key of ["Enter", "Space"]) {
	test(`${key} on the blocker button toggles blocking and leaves the command bar shut`, async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.locator(".url-trigger").hover();

		await page.locator(".url-blocker-btn").focus();
		await page.keyboard.press(key);

		await expect
			.poll(async () => (await sentCommands(page)).filter((c) => c.action === "toggleBlockerAllowlist").map((c) => c.payload.host))
			.toEqual(["example.com"]);
		await expect(page.locator(".command-bar")).toHaveCount(0);
	});
}
