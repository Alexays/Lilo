import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

const LONG_HOST = "staticassetsandmediacontentdelivery.examplecompany.com";

test("a long host never widens a narrow window's detail page", async ({ page }) => {
	await page.setViewportSize({ width: 600, height: 400 });
	await bootChrome(page, initialWorld());
	await page.evaluate(
		(host) => {
			const extension = {
				id: "ext-a",
				name: "Blocker",
				version: "1.0",
				description: "",
				isEnabled: true,
				hasPopup: true,
				hasBackground: false,
				hasContentScripts: true,
				badgeText: "",
				badgeColor: "#5b5bd6",
				hostPermissions: [`https://*.${host}/*`],
				siteAccess: [host],
			};
			window.__lilo!.receive({ event: "extensionsChanged", ids: [extension.id], extensions: [extension] });
			window.__lilo!.receive({ event: "openExtensions" });
		},
		LONG_HOST,
	);
	await page.locator(".extension-row .row-main").click();
	await expect(page.locator(".detail-chip-remove")).toBeVisible();

	const scroller = page.locator(".ui-shell-frame-scroll");
	const { scrollWidth, clientWidth } = await scroller.evaluate((el) => ({ scrollWidth: el.scrollWidth, clientWidth: el.clientWidth }));
	expect(scrollWidth).toBeLessThanOrEqual(clientWidth);
});

for (const [locale, label] of [["en-US", "Activate the extension"], ["fr-FR", "Activer l'extension"]] as const) {
	test.describe(locale, () => {
		test.use({ locale });

		test(`the toolbar action's untitled shortcut reads ${label}`, async ({ page }) => {
			await bootChrome(page, initialWorld());
			await page.evaluate(() => {
				const extension = {
					id: "ext-a", name: "Blocker", version: "1.0", description: "", isEnabled: true, hasPopup: true, hasBackground: false,
					hasContentScripts: false, badgeText: "", badgeColor: "#5b5bd6",
					commands: [{ id: "_execute_action", title: "", key: "K", modifiers: 1179648 }],
				};
				window.__lilo!.receive({ event: "extensionsChanged", ids: [extension.id], extensions: [extension] });
				window.__lilo!.receive({ event: "openExtensions" });
			});
			await page.locator(".extension-row .row-main").click();

			await expect(page.locator(".extension-detail .ui-list-row-title", { hasText: label })).toBeVisible();
		});
	});
}
