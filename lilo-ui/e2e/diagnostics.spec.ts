import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("the tabs fit the narrowest sidebar", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => {
			document.documentElement.style.setProperty("--sidebar-width", "200px");
			window.__lilo!.receive({ event: "openDiagnostics" });
		});
		const panel = page.locator(".diagnostics-panel");
		await panel.waitFor();
		await page.evaluate(() =>
			window.__lilo!.receive({
				event: "extensionDiagnosticsLoaded",
				entries: [{ id: "x", timestamp: 0, level: "error", source: "background", extensionId: "", message: "boom", metadata: {} }],
			}),
		);

		await panel.getByRole("radio", { name: "Journal (1)" }).click();

		const panelBox = (await panel.boundingBox())!;
		const tabsBox = (await panel.locator(".ui-segmented").boundingBox())!;
		expect(panelBox.x).toBe(0);
		expect(tabsBox.x + tabsBox.width).toBeLessThanOrEqual(panelBox.x + panelBox.width);
		// Nothing cut short: no tab's content is wider than the tab.
		const clipped = await panel.locator(".ui-segmented button").evaluateAll((buttons) => buttons.filter((button) => button.scrollWidth > button.clientWidth).length);
		expect(clipped).toBe(0);
	});

	test("a search placeholder too long for the narrowest sidebar ends in an ellipsis", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => {
			document.documentElement.style.setProperty("--sidebar-width", "200px");
			window.__lilo!.receive({ event: "openDiagnostics" });
		});
		await page.locator(".diagnostics-panel").getByRole("radio").nth(2).click();

		await expect(page.locator(".diagnostics-panel .ui-search-field input")).toHaveCSS("text-overflow", "ellipsis");
	});

	test("the boot time holds on one line in the narrowest sidebar", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => {
			document.documentElement.style.setProperty("--sidebar-width", "200px");
			window.__lilo!.receive({ event: "openDiagnostics" });
		});
		await page.locator(".diagnostics-panel").waitFor();
		await page.evaluate(() =>
			window.__lilo!.receive({ event: "startupMetricsLoaded", summary: { bootDurationMilliseconds: 412 }, marks: [], traces: [] }),
		);

		const total = page.locator(".boot-total");
		await expect(total).toHaveText("412 ms");
		const lines = await total.evaluate((el) => {
			const range = document.createRange();
			range.selectNodeContents(el);
			return new Set([...range.getClientRects()].map((rect) => Math.round(rect.top))).size;
		});
		expect(lines).toBe(1);
	});
});
