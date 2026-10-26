import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_2 } from "./fixtures";

test("the Agents space stays out of the spaces settings list and its search", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate((agents) => {
		window.__lilo!.receive({ event: "agentActivity", clients: [], agentsSpaceIds: [agents], agentsProfileId: "profile-1", hiddenAgentsSpaceIds: [agents] });
		window.__lilo!.receive({ event: "openSettings" });
	}, SPACE_2);
	await page.locator(".section-nav-button", { hasText: "Tabs and spaces" }).click();
	const list = page.locator(".settings-section-content");
	await expect(list.getByText("Work", { exact: true })).toBeVisible();
	await expect(list.getByText("Play", { exact: true })).toHaveCount(0);

	await page.locator(".section-nav-toolbar .ui-search-field input").fill("Pla");
	await expect(page.locator(".settings-section-content").getByText("Play", { exact: true })).toHaveCount(0);
});

test("the passwords row names the password manager already installed", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		const extension = {
			id: "ghmbeldphafepmbegfdlkpapadhbakde", name: "Proton Pass: Free Password Manager", version: "1.42.0", description: "", isEnabled: true,
			hasPopup: true, hasBackground: true, hasContentScripts: true, badgeText: "", badgeColor: "#5b5bd6",
		};
		window.__lilo!.receive({ event: "extensionsChanged", ids: [extension.id], extensions: [extension] });
		window.__lilo!.receive({ event: "openSettings" });
	});
	await page.locator(".section-nav-button", { hasText: "Extensions" }).click();
	const row = page.locator(".ui-list-row", { hasText: "Password manager" });
	await expect(row).toContainText("Proton Pass");
	await expect(row.getByRole("button", { name: "Change" })).toBeVisible();
});
