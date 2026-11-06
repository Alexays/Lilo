import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("the history list is one Tab stop, walked with the arrow keys", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openHistory" }));
	let requestId = 0;
	await expect.poll(async () => {
		const request = (await sentCommands(page)).filter((command) => command.action === "loadHistoryPage").at(-1);
		requestId = Number(request?.payload.requestId ?? 0);
		return requestId;
	}).toBeGreaterThan(0);
	const dayStart = new Date().setHours(0, 0, 0, 0);
	const rows = ["one", "two", "three"].map((name, index) => ({
		pageId: name,
		url: `https://${name}.example.com/`,
		title: name,
		host: `${name}.example.com`,
		lastVisitAt: dayStart + 3_600_000 * (3 - index),
		visits: 1,
		dayStart,
	}));
	await page.evaluate((page) => window.__lilo!.receive({ event: "historyPage", ...page, favicons: {} }), { requestId, rows });

	const items = page.getByRole("tree").getByRole("treeitem");
	await expect(items).toHaveCount(3);
	await expect(page.locator("[role=tree] [tabindex='0']")).toHaveCount(1);
	await expect(items.first()).toHaveAttribute("tabindex", "0");

	await items.first().focus();
	await page.keyboard.press("ArrowDown");
	await expect(items.nth(1)).toBeFocused();
	await expect(items.nth(1)).toHaveAttribute("tabindex", "0");
	await expect(items.first()).toHaveAttribute("tabindex", "-1");
	await page.keyboard.press("End");
	await expect(items.last()).toBeFocused();
});
