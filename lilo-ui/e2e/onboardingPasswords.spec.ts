import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const BITWARDEN = "nngceckbapebfimnlniiiahkandclblb";

test("the import screen installs a manager from the store and shows it added", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "onboardingState", show: true, step: 2, usage: "browse" }));
	const card = page.locator(".onb");
	await expect(card.getByRole("heading", { name: "Your passwords" })).toBeVisible();
	// The managers wait behind one row: the screen reads as the browser choice first.
	await expect(card.getByRole("listitem")).toHaveCount(0);
	await card.getByRole("button", { name: "Choose" }).click();
	await expect(card.getByRole("button", { name: "Choose" })).toHaveAttribute("aria-expanded", "true");
	await expect(card.getByRole("listitem").filter({ hasText: "iCloud Passwords" })).toContainText("Soon");
	await expect(card.getByRole("listitem").filter({ hasText: "iCloud Passwords" }).getByRole("button")).toHaveCount(0);

	await card.getByRole("button", { name: "Add Bitwarden" }).click();

	const install = (await sentCommands(page)).find((command) => command.action === "installExtension");
	expect(install?.payload.path).toBe(`https://chromewebstore.google.com/detail/${BITWARDEN}`);
	await expect(card.getByRole("button", { name: "Add Bitwarden" })).toBeDisabled();

	await page.evaluate((id) => window.__lilo!.receive({
		event: "extensionsChanged",
		ids: [id],
		extensions: [{ id, name: "Bitwarden", version: "1.0", description: "", isEnabled: true, hasPopup: true, hasBackground: true, hasContentScripts: true }],
	}), BITWARDEN);
	await page.evaluate((id) => window.__lilo!.receive({ event: "extensionActionCompleted", id, action: "install", success: true }), BITWARDEN);

	await expect(card.getByRole("listitem").filter({ hasText: "Bitwarden" })).toContainText("Added");
	await expect(card.locator(".ob-group .ob-row .ob-done").first()).toHaveText("Bitwarden");
});
