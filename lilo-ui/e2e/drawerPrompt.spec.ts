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

test("an agent's answers fit the drawer, a long site included", async ({ page }) => {
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

test("an agent asking to connect gets a modal, and a waiting extension prompt keeps its drawer", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		window.__lilo!.receive({
			event: "extensionPermissionRequested", requestId: "e1", extensionName: "Okta Verify", permissions: [], origins: ["https://example.okta.com"], type: "urls",
		});
		window.__lilo!.receive({ event: "agentControlRequested", requestId: "a1", clientName: "Claude Code", executable: "/usr/local/bin/claude", profileName: "", action: null });
	});
	const modal = page.getByRole("dialog", { name: "Claude Code wants to control Lilo" });
	await expect(modal).toBeVisible();
	await expect(modal).toContainText("/usr/local/bin/claude");
	await expect(modal.getByRole("button", { name: /Don't Allow/ })).toBeFocused();
	await expect(page.locator(".url-drawer-clip")).toContainText("Okta Verify");

	await page.keyboard.press("Meta+Enter");
	await expect(modal).toHaveCount(0);
	const response = (await sentCommands(page)).find((command) => command.action === "agentControlResponse");
	expect(response?.payload).toMatchObject({ requestId: "a1", granted: true });
});

test("Escape on an agent's connection request does not allow it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() =>
		window.__lilo!.receive({ event: "agentControlRequested", requestId: "a1", clientName: "Codex", executable: "", profileName: "Work", action: null }),
	);
	await expect(page.getByRole("dialog", { name: "Codex wants to use the profile Work" })).toBeVisible();

	await page.keyboard.press("Escape");

	await expect(page.getByRole("dialog")).toHaveCount(0);
	const response = (await sentCommands(page)).find((command) => command.action === "agentControlResponse");
	expect(response?.payload).toMatchObject({ requestId: "a1", granted: false });
});

test("a request opened from the address over the page hangs down into it, never off the window", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), addressPlacement: "page" });
	await page.evaluate(() =>
		window.__lilo!.receive({ event: "agentControlRequested", requestId: "a1", clientName: "Claude Code", executable: "", profileName: "", action: { kind: "click", label: "Send", site: "mail.example.com", tab: "Inbox" } }),
	);
	const drawer = page.locator(".page-toolbar .url-drawer-clip");
	await expect(drawer).toContainText("Claude Code");

	const address = page.locator(".page-toolbar .address");
	await expect.poll(async () => (await address.boundingBox())!.height).toBeGreaterThan(80);
	const box = (await address.boundingBox())!;
	expect(box.y).toBeGreaterThanOrEqual(0);
	expect((await drawer.boundingBox())!.y).toBeGreaterThan(box.y);
});

test("a request slides a hidden sidebar out so it can be answered", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.mouse.move(600, 300);
	await page.evaluate(() => window.__lilo!.receive({ event: "sidebarVisibilityChanged", visible: false, width: 260 }));
	await expect(page.locator(".sidebar")).toHaveClass(/sidebar-hidden/);

	await page.evaluate(() =>
		window.__lilo!.receive({ event: "agentControlRequested", requestId: "a1", clientName: "Claude", executable: "", profileName: "", action: { kind: "click", label: "Send", site: "mail.example.com", tab: "Inbox" } }),
	);

	await expect(page.locator(".sidebar")).not.toHaveClass(/sidebar-hidden/);
	await expect(page.locator(".url-drawer-clip")).toContainText("Claude");
});

for (const [position, address] of [["left", "tabs"], ["left", "page"], ["left", "hidden"], ["right", "page"], ["right", "hidden"], ["top", "tabs"], ["top", "page"], ["top", "hidden"], ["bottom", "tabs"], ["bottom", "page"], ["bottom", "hidden"]] as const) {
	for (const mode of ["", ", the tabs hidden", ", in full screen with the tabs hidden"]) {
		test(`an agent's request can be answered with the tabs ${position}, the address ${address === "hidden" ? "hidden" : `in the ${address}`}${mode}`, async ({ page }) => {
			const strip = position === "top" || position === "bottom";
			await bootChrome(page, { ...initialWorld(), tabPosition: position, addressPlacement: address }, strip ? ".tab-strip .strip-tab" : undefined);
			await page.mouse.move(600, 300);
			if (mode) await page.evaluate(() => window.__lilo!.receive({ event: "sidebarVisibilityChanged", visible: false, width: 260 }));
			if (mode.includes("full screen")) await page.evaluate(() => window.__lilo!.receive({ event: "windowFullscreenChanged", isFullscreen: true }));

			await page.evaluate(() =>
				window.__lilo!.receive({ event: "agentControlRequested", requestId: "a1", clientName: "Claude", executable: "", profileName: "", action: { kind: "click", label: "Send", site: "mail.example.com", tab: "Inbox" } }),
			);

			const allow = page.locator(".url-drawer-clip .prompt-actions button").last();
			await expect(allow).toBeInViewport({ ratio: 1 });
			await allow.click();
			await expect.poll(() => sentCommands(page).then((all) => all.some((m) => m.action === "agentControlResponse"))).toBe(true);
			if (address === "hidden") await expect(page.locator(".url-display")).toHaveCount(0);
		});
	}
}

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
	await page.locator("section[aria-label=\"Downloads\"]").waitFor();
	await page.evaluate(() =>
		window.__lilo!.receive({ event: "permissionRequest", requestId: "req-1", tabId: "tab-alpha", type: "camera", origin: "meet.example.com" }),
	);

	await page.keyboard.press("Escape");

	await expect(page.locator("section[aria-label=\"Downloads\"]")).toHaveCount(0);
	await expect(page.locator(".url-drawer.open")).toBeVisible();
	expect((await sentCommands(page)).some((command) => command.action === "permissionResponse")).toBe(false);
});
