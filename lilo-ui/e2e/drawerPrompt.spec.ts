import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

async function expectActionsInside(page: Page) {
	const buttons = page.locator(".prompt-actions button");
	await expect(buttons.first()).toBeVisible();
	const drawer = (await page.locator(".url-drawer-clip").boundingBox())!;
	for (const box of await buttons.evaluateAll((all) => all.map((button) => button.getBoundingClientRect().toJSON()))) {
		expect(box.left).toBeGreaterThanOrEqual(drawer.x);
		expect(box.right).toBeLessThanOrEqual(drawer.x + drawer.width);
	}
}

test("an agent's three answers fit the drawer, a long site included", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() =>
		window.__lilo!.receive({
			event: "agentControlRequested",
			requestId: "a1",
			clientName: "Claude Code",
			executable: "",
			profileName: "",
			action: { kind: "click", label: "Send", site: "notifications.mail.example-company.co.uk", tab: "Inbox" },
		}),
	);

	await expectActionsInside(page);
});

test("an agent asking to connect shows ahead of a waiting extension prompt, which comes back after", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		window.__lilo!.receive({
			event: "extensionPermissionRequested", requestId: "e1", extensionName: "Okta Verify", permissions: [], origins: ["https://example.okta.com"], type: "urls",
		});
		window.__lilo!.receive({ event: "agentControlRequested", requestId: "a1", clientName: "Claude Code", executable: "/usr/local/bin/claude", profileName: "" });
	});
	const drawer = page.locator(".url-drawer-clip");
	await expect(drawer).toContainText("Claude Code");
	await expect(drawer).not.toContainText("Okta Verify");

	await drawer.locator(".prompt-actions button").last().click();
	await expect(drawer).toContainText("Okta Verify");
});

test("a request slides a hidden sidebar out so it can be answered", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.mouse.move(600, 300);
	await page.evaluate(() => window.__lilo!.receive({ event: "sidebarVisibilityChanged", visible: false, width: 260 }));
	await expect(page.locator(".sidebar")).toHaveClass(/sidebar-hidden/);

	await page.evaluate(() =>
		window.__lilo!.receive({ event: "agentControlRequested", requestId: "a1", clientName: "Claude", executable: "/usr/local/bin/claude", profileName: "" }),
	);

	await expect(page.locator(".sidebar")).not.toHaveClass(/sidebar-hidden/);
	await expect(page.locator(".url-drawer-clip")).toContainText("Claude");
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("the default browser invite's answers fit the narrowest sidebar", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => {
			document.documentElement.style.setProperty("--sidebar-width", "200px");
			window.__lilo!.receive({ event: "defaultBrowserStatusLoaded", isDefault: false, shouldInvite: true });
		});

		await expectActionsInside(page);
	});
});

test("Escape dismisses a site's permission request: denied for now, not remembered", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() =>
		window.__lilo!.receive({ event: "permissionRequest", requestId: "req-1", tabId: "tab-alpha", type: "geolocation", origin: "maps.example.com" }),
	);
	await expect(page.locator(".url-drawer.open")).toBeVisible();

	await page.keyboard.press("Escape");

	await expect(page.locator(".url-drawer.open")).toHaveCount(0);
	const response = (await sentCommands(page)).find((command) => command.action === "permissionResponse");
	expect(response?.payload).toEqual({ requestId: "req-1", granted: false, remember: false });
});

test("Escape that closes a panel leaves a site's permission request waiting", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openDownloads" }));
	await page.locator(".downloads-panel").waitFor();
	await page.evaluate(() =>
		window.__lilo!.receive({ event: "permissionRequest", requestId: "req-1", tabId: "tab-alpha", type: "camera", origin: "meet.example.com" }),
	);

	await page.keyboard.press("Escape");

	await expect(page.locator(".downloads-panel")).toHaveCount(0);
	await expect(page.locator(".url-drawer.open")).toBeVisible();
	expect((await sentCommands(page)).some((command) => command.action === "permissionResponse")).toBe(false);
});
