import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_2 } from "./fixtures";

test("the Agents space stays out of the spaces settings list and its search", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate((agents) => {
		window.__lilo!.receive({ event: "agentActivity", clients: [], agentsSpaceId: agents, agentsProfileId: "profile-1", agentsSpaceVisible: false });
		window.__lilo!.receive({ event: "openSettings" });
	}, SPACE_2);
	await page.locator(".section-nav-button", { hasText: "Tabs and spaces" }).click();
	const list = page.locator(".settings-section-content");
	await expect(list.getByText("Work", { exact: true })).toBeVisible();
	await expect(list.getByText("Play", { exact: true })).toHaveCount(0);

	await page.locator(".section-nav-toolbar .ui-search-field input").fill("Pla");
	await expect(page.locator(".settings-section-content").getByText("Play", { exact: true })).toHaveCount(0);
});
