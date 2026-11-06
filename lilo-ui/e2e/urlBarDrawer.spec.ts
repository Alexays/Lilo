import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands, type FakeHostWorld } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

// Active tab (tab-alpha, https://example.com/tab-alpha) with a live camera: the site-controls
// button shows and opens the Site drawer.
function worldWithActiveCamera(): FakeHostWorld {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].find((tab) => tab.id === "tab-alpha")!.isCameraActive = true;
	return world;
}

async function receive(page: Page, message: Record<string, unknown>) {
	await page.evaluate((msg) => window.__lilo!.receive(msg), message);
}

test("the site-controls button opens the Site drawer, which sets a permission", async ({ page }) => {
	await bootChrome(page, worldWithActiveCamera());
	await page.locator(".permissions-btn").click();

	const drawer = page.locator(".url-drawer.open");
	await expect(drawer).toContainText("Camera");
	await drawer.getByRole("combobox", { name: "Camera" }).selectOption("blocked");

	const set = (await sentCommands(page)).find((c) => c.action === "setSitePermission");
	expect(set?.payload).toEqual({ origin: "https://example.com", type: "camera", allow: false });
});

test("the Site drawer counts the site's hidden elements and shows them again", async ({ page }) => {
	await bootChrome(page, worldWithActiveCamera());
	await receive(page, { event: "settingsLoaded", settings: { hiddenElements: JSON.stringify({ "example.com": [".promo", "#banner"] }) } });
	await page.locator(".permissions-btn").click();

	const drawer = page.locator(".url-drawer.open");
	await expect(drawer).toContainText("2 hidden elements");
	await drawer.getByRole("button", { name: "Show again" }).click();

	const commands = await sentCommands(page);
	expect(commands.find((c) => c.action === "setSetting")?.payload).toEqual({ key: "hiddenElements", value: "{}" });
	expect(commands.some((c) => c.action === "reload")).toBe(true);
	await expect(drawer).not.toContainText("hidden elements");
});

test("the Site drawer's click zone reaches up over its arrow to the address", async ({ page }) => {
	await bootChrome(page, worldWithActiveCamera());
	await page.locator(".permissions-btn").click();
	const drawer = page.locator(".url-drawer.open");
	await expect(drawer).toBeVisible();
	await page.waitForFunction(() => document.querySelector(".url-drawer")!.getAnimations().length === 0);

	const box = await drawer.evaluate((el) => el.getBoundingClientRect().toJSON() as DOMRect);
	const address = await page.locator(".url-display").evaluate((el) => el.getBoundingClientRect().bottom);
	await expect
		.poll(async () => {
			const zone = (await sentCommands(page))
				.filter((c) => c.action === "registerInteractiveZones")
				.flatMap((c) => (c.payload as { zones: { id: string; y: number; height: number }[] }).zones)
				.filter((z) => z.id === "url-bar-drawer")
				.at(-1);
			return !!zone && zone.y <= address && zone.y + zone.height >= box.bottom;
		})
		.toBe(true);
});

test("Escape closes the Site drawer", async ({ page }) => {
	await bootChrome(page, worldWithActiveCamera());
	await page.locator(".permissions-btn").click();
	await expect(page.locator(".url-drawer.open")).toBeVisible();

	await page.keyboard.press("Escape");
	await expect(page.locator(".url-drawer.open")).toHaveCount(0);
});

test("Escape taken by the command bar leaves the Site drawer open", async ({ page }) => {
	await bootChrome(page, worldWithActiveCamera());
	await page.locator(".permissions-btn").click();
	await expect(page.locator(".url-drawer.open")).toBeVisible();
	await receive(page, { event: "openCommandBar" });
	const input = page.locator(".command-bar-input");
	await input.fill(":");

	await input.press("Escape");

	await expect(input).toHaveValue("");
	await expect(page.locator(".url-drawer.open")).toBeVisible();
});

test("no capture on the active tab means no site-controls button", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await expect(page.locator(".permissions-btn")).toHaveCount(0);
});

test("a site permission request asks in plain language and sends the answer", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, {
		event: "permissionRequest",
		requestId: "req-1",
		tabId: "tab-alpha",
		type: "camera",
		origin: "meet.example.com",
	});

	const drawer = page.locator(".url-drawer.open");
	await expect(drawer).toContainText("meet.example.com wants to use your camera");
	await drawer.getByRole("button", { name: "Allow", exact: true }).click();

	await expect(page.locator(".url-drawer.open")).toHaveCount(0);
	const response = (await sentCommands(page)).find((c) => c.action === "permissionResponse");
	expect(response?.payload).toEqual({ requestId: "req-1", granted: true });
});

test("the site-controls button showing up keeps the address bar's height", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const without = (await page.locator(".url-trigger").first().boundingBox())!.height;

	await bootChrome(page, worldWithActiveCamera());
	await expect(page.locator(".permissions-btn")).toBeVisible();

	expect((await page.locator(".url-trigger").first().boundingBox())!.height).toBe(without);
});
