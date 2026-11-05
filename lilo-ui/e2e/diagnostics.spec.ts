import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("the navigation counts the log's errors and opens it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openDiagnostics" }));
	await page.getByRole("region", { name: "Diagnostics" }).waitFor();
	await page.evaluate(() =>
		window.__lilo!.receive({
			event: "extensionDiagnosticsLoaded",
			entries: [{ id: "x", timestamp: 0, level: "error", source: "background", extensionId: "", message: "boom", metadata: {} }],
		}),
	);

	const log = page.locator(".section-nav-panel").getByRole("button", { name: /^Log/ });
	await expect(log).toContainText("1");
	await log.click();
	await expect(page.locator(".log-message")).toContainText("boom");
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("the boot time holds on one line", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openDiagnostics" }));
		await page.getByRole("region", { name: "Diagnostics" }).waitFor();
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
