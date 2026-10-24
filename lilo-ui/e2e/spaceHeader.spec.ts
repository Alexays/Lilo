import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("the Space header's icon sits bare on the favicon column, its name on the titles' column", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const pane = page.locator(".space-pane").first();
	const box = async (selector: string) => (await pane.locator(selector).first().boundingBox())!;

	const icon = await box(".space-icon-stack");
	const favicon = await box('.tab-list [data-tab-id="tab-beta"] .tab-icon');
	expect([icon.width, icon.height]).toEqual([favicon.width, favicon.height]);
	expect(icon.x).toBeCloseTo(favicon.x, 0);
	expect((await box(".space-name")).x).toBeCloseTo((await box('.tab-list [data-tab-id="tab-beta"] .tab-title')).x, 0);
	expect(await pane.locator(".space-icon-stack").evaluate((el) => getComputedStyle(el).backgroundColor)).toBe("rgba(0, 0, 0, 0)");
});
