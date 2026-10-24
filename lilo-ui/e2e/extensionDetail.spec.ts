import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
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

test("a logo sits on the row without the accent tile, enabled or disabled", async ({ page }) => {
	await bootChrome(page, initialWorld());
	// A 1x1 transparent PNG: the tile behind it must not show through.
	const icon = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
	await page.evaluate((iconDataURL) => {
		const base = { version: "1.0", description: "", hasPopup: false, hasBackground: false, hasContentScripts: false, badgeText: "", badgeColor: "#5b5bd6", iconDataURL };
		const extensions = [
			{ ...base, id: "ext-on", name: "Enabled", isEnabled: true },
			{ ...base, id: "ext-off", name: "Disabled", isEnabled: false },
		];
		window.__lilo!.receive({ event: "extensionsChanged", ids: extensions.map((e) => e.id), extensions });
		window.__lilo!.receive({ event: "openExtensions" });
	}, icon);
	const tiles = page.locator(".extension-row .row-icon");
	await expect(tiles).toHaveCount(2);
	for (const tile of await tiles.all()) {
		await expect(tile.locator("img")).toBeVisible();
		await expect(tile).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
	}
});

const STORE_URL = "https://chromewebstore.google.com/detail/aaaabbbbccccddddeeeeffffgggghhhh";

for (const webStoreURL of [STORE_URL, ""]) {
	test(`the detail page ${webStoreURL ? "opens a Web Store extension's store page" : "offers no store page for an unpacked extension"}`, async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate((webStoreURL) => {
			const extension = {
				id: "ext-a", name: "Blocker", version: "1.0", description: "", isEnabled: true, hasPopup: false, hasBackground: false,
				hasContentScripts: false, badgeText: "", badgeColor: "#5b5bd6", webStoreURL,
			};
			window.__lilo!.receive({ event: "extensionsChanged", ids: [extension.id], extensions: [extension] });
			window.__lilo!.receive({ event: "openExtensions" });
		}, webStoreURL);
		await page.locator(".extension-row .row-main").click();
		await expect(page.locator(".extension-detail")).toBeVisible();
		const storeRow = page.locator(".extension-detail .ui-list-row", { hasText: "Chrome Web Store" });

		if (!webStoreURL) {
			await expect(storeRow).toHaveCount(0);
			return;
		}
		await storeRow.getByRole("button", { name: "Open" }).click();
		await expect.poll(async () => (await sentCommands(page)).find((c) => c.action === "createTab")?.payload.url).toBe(STORE_URL);
	});
}
