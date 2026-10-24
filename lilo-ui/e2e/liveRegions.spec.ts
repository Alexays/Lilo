import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

const announcer = (page: Page) => page.locator(".live-announcer");

function download(page: Page, state: string, bytesReceived: number, error?: string): Promise<void> {
	return page.evaluate(({ state, bytesReceived, error }) => window.__lilo!.receive({
		event: "downloadUpdated",
		id: 7, url: "https://example.com/report.pdf", filename: "report.pdf", bytesReceived, totalBytes: 100,
		state, startedAt: 1, fileMissing: false, source: "wk", ...(error && { error }),
	}), { state, bytesReceived, error });
}

test("a download is announced once as it ends, never on progress", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await download(page, "inProgress", 10);
	await download(page, "inProgress", 50);
	await expect(announcer(page)).toHaveCount(0);

	await download(page, "complete", 100);
	await expect(announcer(page)).toHaveText("report.pdf downloaded");
	await expect(announcer(page)).toHaveAttribute("aria-live", "polite");

	await download(page, "complete", 100);
	await expect(announcer(page)).toHaveText("report.pdf downloaded");
});

test("closing a tab is announced", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(() => window.__lilo!.receive({ event: "tabClosedUndoable", title: "Alpha Docs" }));
	await expect(announcer(page)).toHaveText("\"Alpha Docs\" closed");
});

test("the same message twice in a row is spoken again", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const closed = () => page.evaluate(() => window.__lilo!.receive({ event: "tabClosedUndoable", title: "Alpha Docs" }));

	await closed();
	await expect(announcer(page)).toHaveText("\"Alpha Docs\" closed");
	const first = await announcer(page).textContent();
	await closed();

	await expect.poll(() => announcer(page).textContent()).not.toBe(first);
});
