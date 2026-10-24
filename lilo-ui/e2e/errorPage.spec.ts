import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

for (const code of [-1009, -1202, -1003, -1001, -1100]) {
	test(`the ${code} error page draws a line icon, not an emoji`, async ({ page }) => {
		const world = initialWorld();
		world.tabsBySpace[SPACE_1][0] = {
			...world.tabsBySpace[SPACE_1][0],
			hasNavigationError: true,
			navigationErrorCode: code,
			navigationErrorDomain: "NSURLErrorDomain",
			navigationErrorDescription: "",
			navigationErrorURL: "https://example.com/",
		};
		await bootChrome(page, world);

		const icon = page.locator(".error-page .error-icon");
		await expect(icon.locator("svg")).toBeVisible();
		await expect(icon).toHaveText("");
	});
}
