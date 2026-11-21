import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import type { BridgeTabSnapshot } from "../src/lib/bridge/protocol";

function setNeverSleep(page: Page, tab: BridgeTabSnapshot, neverSleep: boolean): Promise<void> {
	return page.evaluate((m) => window.__lilo!.receive(m as never), {
		event: "browserStatePatch",
		operations: [{ kind: "tabUpdated", spaceId: tab.spaceId, tab: { ...tab, neverSleep } }],
	});
}

for (const colorScheme of ["light", "dark"] as const) {
	test(`a kept-loaded tab shows a mark and is labelled in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme });
		const world = initialWorld();
		await bootChrome(page, world);
		const tab = world.tabsBySpace[SPACE_1][1];
		const row = page.locator(`.tab-item[data-tab-id="${tab.id}"]`);
		await expect(row.locator(".doze-ring.kept")).toHaveCount(0);

		await setNeverSleep(page, tab, true);
		await expect(row.locator(".doze-ring.kept")).toHaveCount(1);
		await expect(row).toHaveAccessibleName("Beta Mail, Kept loaded");

		await setNeverSleep(page, tab, false);
		await expect(row.locator(".doze-ring.kept")).toHaveCount(0);
		await expect(row).toHaveAccessibleName("Beta Mail");
	});
}

test("the Tabs settings keep a list of sites that stay loaded", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: "Tabs and spaces" }).click();

	const field = page.getByRole("textbox", { name: "Sites kept loaded" });
	await expect(field).toHaveAttribute("placeholder", "mail.example.com, example.org");
	await field.fill("  mail.example.com, example.org ");
	await field.press("Enter");

	const sent = (await sentCommands(page)).filter((command) => command.action === "setSetting" && command.payload.key === "tabSleepAllowlist");
	expect(sent.at(-1)?.payload.value).toBe("mail.example.com, example.org");
});
