import { expect, test, type Page } from "@playwright/test";
import type { BridgeProfileSnapshot } from "../src/lib/bridge/protocol";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const PERSONAL: BridgeProfileSnapshot = { id: "profile-1", name: "Personal", isDefault: true, color: "#f1a7a5" };
const WORK: BridgeProfileSnapshot = { id: "profile-2", name: "Work", isDefault: false, color: "#b39df4" };

const row = (id: string, name: string, isEnabled = true) => ({
	id, name, version: "1.0", description: "", isEnabled, hasPopup: false, hasBackground: false,
	hasContentScripts: false, badgeText: "", badgeColor: "",
});

async function openExtensions(page: Page, profiles: BridgeProfileSnapshot[]): Promise<void> {
	await bootChrome(page, { ...initialWorld(), profiles, activeProfileId: PERSONAL.id });
	await page.evaluate((extension) => {
		window.__lilo!.receive({ event: "extensionsChanged", ids: [extension.id], extensions: [extension] });
		window.__lilo!.receive({ event: "openExtensions" });
	}, row("ext-home", "Home Blocker"));
	await expect(page.locator(".extension-row")).toHaveCount(1);
}

const profileSelect = (page: Page) => page.getByRole("combobox", { name: "Profile" });

async function showWork(page: Page): Promise<void> {
	await profileSelect(page).selectOption(WORK.id);
	await expect.poll(async () => (await sentCommands(page)).findLast((c) => c.action === "getProfileExtensions")?.payload)
		.toEqual({ profileId: WORK.id, live: false });
	await page.evaluate((extensions) => {
		window.__lilo!.receive({ event: "profileExtensionsLoaded", profileId: "profile-2", live: false, extensions });
	}, [row("ext-work", "Work Vault", false)]);
}

test("the profile selector shows only with two profiles or more", async ({ page }) => {
	await openExtensions(page, [PERSONAL]);
	await expect(profileSelect(page)).toHaveCount(0);

	await page.evaluate((profile) => window.__lilo!.receive({ event: "profileCreated", ...profile }), WORK);
	await expect(profileSelect(page)).toHaveValue(PERSONAL.id);
});

test("another profile lists its own extensions, and its actions name it", async ({ page }) => {
	await openExtensions(page, [PERSONAL, WORK]);
	await showWork(page);

	await expect(page.locator(".extension-row .row-name")).toHaveText(["Work Vault"]);
	await expect(page.locator(".add-hint")).toHaveText("Installs into Personal, the profile of this window.");
	await page.locator(".ui-toggle", { has: page.getByRole("checkbox", { name: "Work Vault enabled" }) }).click();
	await expect.poll(async () => (await sentCommands(page)).findLast((c) => c.action === "enableExtension")?.payload)
		.toEqual({ id: "ext-work", profileId: WORK.id });

	await page.locator(".extension-row .row-menu").click();
	await expect.poll(async () => (await sentCommands(page)).findLast((c) => c.action === "showExtensionContextMenu")?.payload.profileId)
		.toBe(WORK.id);

	await profileSelect(page).selectOption(PERSONAL.id);
	await expect(page.locator(".extension-row .row-name")).toHaveText(["Home Blocker"]);
	await expect(page.locator(".add-hint")).toHaveCount(0);
});

test("another profile's detail page waits for its full rows", async ({ page }) => {
	await openExtensions(page, [PERSONAL, WORK]);
	await showWork(page);

	await page.locator(".extension-row .row-main").click();
	await expect.poll(async () => (await sentCommands(page)).findLast((c) => c.action === "getProfileExtensions")?.payload)
		.toEqual({ profileId: WORK.id, live: true });
	await expect(page.locator(".extension-detail")).toHaveCount(0);

	await page.evaluate((extensions) => {
		window.__lilo!.receive({ event: "profileExtensionsLoaded", profileId: "profile-2", live: true, extensions });
	}, [{ ...row("ext-work", "Work Vault"), permissions: ["storage"] }]);
	await page.locator(".ui-toggle", { has: page.getByRole("checkbox", { name: "Allow in private spaces" }) }).click();
	await expect.poll(async () => (await sentCommands(page)).findLast((c) => c.action === "setExtensionPrivateAccess")?.payload)
		.toEqual({ id: "ext-work", allowed: true, profileId: WORK.id });
});

test("closing the settings brings the window's profile back", async ({ page }) => {
	await openExtensions(page, [PERSONAL, WORK]);
	await showWork(page);
	await expect(page.locator(".extension-row .row-name")).toHaveText(["Work Vault"]);

	await page.keyboard.press("Escape");
	await expect(page.locator(".ui-shell-frame")).toHaveCount(0);
	await page.evaluate(() => window.__lilo!.receive({ event: "openExtensions" }));

	await expect(profileSelect(page)).toHaveValue(PERSONAL.id);
	await expect(page.locator(".extension-row .row-name")).toHaveText(["Home Blocker"]);
});
