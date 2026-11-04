import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

async function openWithProcesses(page: Page, processes: { id: string; tabIds: string[]; bytes: number }[]) {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openProcessManager" }));
	await page.getByRole("region", { name: "Process Manager" }).waitFor();
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

	await page.locator(".object-row .row-hit").first().click();

	const detail = page.locator(".object-row.expanded .detail");
	await expect(detail).toContainText("shared with 1 other tab");
	await expect(detail).not.toContainText("tabs");
});

test("a fourth tab alone reads as one other in the legend", async ({ page }) => {
	await openWithProcesses(
		page,
		["tab-alpha", "tab-beta", "tab-gamma", "tab-home"].map((id, index) => ({ id: `p-${id}`, tabIds: [id], bytes: (4 - index) * 100_000_000 })),
	);

	await expect(page.locator(".memory-legend")).toContainText("1 other");
	await expect(page.locator(".memory-legend")).not.toContainText("others");
});

test("Force Quit asks first", async ({ page }) => {
	await openWithProcesses(page, [{ id: "p1", tabIds: ["tab-alpha"], bytes: 100_000_000 }]);
	await page.locator(".object-row .row-hit").first().click();
	await page.locator(".object-row.expanded").getByRole("button", { name: "Force Quit" }).click();

	await expect(page.locator('[data-modal="confirm-modal"]')).toBeVisible();
});
