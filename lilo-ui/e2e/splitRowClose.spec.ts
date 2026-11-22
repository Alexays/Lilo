// The × on a pane of a split row takes that tab out of the split; the host echoes the
// dissolved split and both tabs stay listed.
import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { splitWorld } from "./fixtures";

test("the close button on a split row's tab unsplits it", async ({ page }) => {
	await bootChrome(page, splitWorld());
	const row = page.locator(".split-row");
	await expect(row).toBeVisible();
	await expect(row.locator(".split-pane")).toHaveCount(2);

	const pane = row.locator(".split-pane").nth(1);
	await pane.hover();
	const close = pane.locator(".close-btn");
	await expect(close).toHaveClass(/visible/);
	await close.click();

	await expect
		.poll(async () =>
			(await sentCommands(page)).filter((c) => c.action === "unsplitTab"),
		)
		.toEqual([{ action: "unsplitTab", payload: { tabId: "tab-beta" } }]);
	expect((await sentCommands(page)).some((c) => c.action === "closeTab")).toBe(false);

	// Two panes left means the split dissolved: the row is gone, both tabs remain.
	await expect(page.locator(".split-row")).toHaveCount(0);
	await expect(page.locator('.tab-list [data-tab-id="tab-alpha"]')).toBeVisible();
	await expect(page.locator('.tab-list [data-tab-id="tab-beta"]')).toBeVisible();
});
