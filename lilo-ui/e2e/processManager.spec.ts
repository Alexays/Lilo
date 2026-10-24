import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

async function openWithProcesses(page: Page, processes: { id: string; tabIds: string[]; bytes: number }[]) {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openProcessManager" }));
	await page.locator(".process-panel").waitFor();
	await page.evaluate(
		(list) =>
			window.__lilo!.receive({
				event: "processSnapshotUpdated",
				processes: list.map(({ id, tabIds, bytes }, index) => ({
					id,
					kind: "webContent",
					pid: 100 + index,
					tabs: tabIds.map((tabId) => ({ id: tabId, spaceId: "space-1", title: tabId, url: `https://example.com/${tabId}`, lifecycle: "active", isAudioPlaying: false, isMicrophoneActive: false, isCameraActive: false, isScreenSharing: false })),
					metrics: { residentSizeBytes: bytes },
					webProcessStateLabel: "",
				})),
			}),
		processes,
	);
}

test("a process shared by two tabs counts one other tab", async ({ page }) => {
	await openWithProcesses(page, [{ id: "p1", tabIds: ["tab-alpha", "tab-beta"], bytes: 200_000_000 }]);

	await page.locator(".process-panel .tab-row").first().click();

	await expect(page.locator(".process-panel .details-meta")).toContainText("shared with 1 other tab");
	await expect(page.locator(".process-panel .details-meta")).not.toContainText("tabs");
});

test("a fourth tab alone reads as one other in the legend", async ({ page }) => {
	await openWithProcesses(
		page,
		["tab-alpha", "tab-beta", "tab-gamma", "tab-home"].map((id, index) => ({ id: `p-${id}`, tabIds: [id], bytes: (4 - index) * 100_000_000 })),
	);

	await expect(page.locator(".process-panel .memory-legend")).toContainText("1 other");
	await expect(page.locator(".process-panel .memory-legend")).not.toContainText("others");
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("the sleep notice puts its button under the text in the narrowest sidebar", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => {
			document.documentElement.style.setProperty("--sidebar-width", "200px");
			window.__lilo!.receive({ event: "openProcessManager" });
		});
		await page.locator(".process-panel").waitFor();
		const hidden = { id: "tab-zeta", spaceId: "space-2", title: "Zeta", url: "https://example.com/zeta", lifecycle: "loaded-hidden", isAudioPlaying: false, isMicrophoneActive: false, isCameraActive: false, isScreenSharing: false };
		await page.evaluate(
			(tab) => window.__lilo!.receive({ event: "processSnapshotUpdated", processes: [{ id: "p", kind: "webContent", pid: 9, tabs: [tab], metrics: { residentSizeBytes: 100_000_000 }, webProcessStateLabel: "" }] }),
			hidden,
		);

		const copy = (await page.locator(".reclaim-copy").boundingBox())!;
		const button = (await page.locator(".reclaim .link-button").boundingBox())!;
		expect(button.y).toBeGreaterThanOrEqual(copy.y + copy.height);
		expect(copy.height).toBeLessThan(40);
	});

	test("the force quit sheet's buttons each hold on one line in the narrowest sidebar", async ({ page }) => {
		await openWithProcesses(page, [{ id: "p1", tabIds: ["tab-alpha"], bytes: 100_000_000 }]);
		await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "200px"));
		await page.locator(".process-panel .tab-row").first().click();
		await page.locator(".process-panel .small-button.danger").click();
		await expect(page.locator(".confirm-sheet.visible")).toBeVisible();

		const lines = await page.locator(".confirm-sheet .sheet-btn").evaluateAll((buttons) =>
			buttons.map((button) => {
				const range = document.createRange();
				range.selectNodeContents(button);
				return new Set([...range.getClientRects()].map((rect) => Math.round(rect.top))).size;
			}),
		);
		expect(lines).toEqual([1, 1]);
	});

	test("the memory total holds on one line in the narrowest sidebar", async ({ page }) => {
		await openWithProcesses(page, [{ id: "p1", tabIds: ["tab-alpha"], bytes: 1_300_000_000 }]);
		await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "200px"));

		const total = page.locator(".overview-total");
		await expect(total).toHaveText("1,2 Go");
		const lines = await total.evaluate((el) => {
			const range = document.createRange();
			range.selectNodeContents(el);
			return new Set([...range.getClientRects()].map((rect) => Math.round(rect.top))).size;
		});
		expect(lines).toBe(1);
	});
});
