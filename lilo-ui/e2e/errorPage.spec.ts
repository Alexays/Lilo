import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

function failedWorld(code: number) {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1][0] = {
		...world.tabsBySpace[SPACE_1][0],
		hasNavigationError: true,
		navigationErrorCode: code,
		navigationErrorDomain: "NSURLErrorDomain",
		navigationErrorDescription: "",
		navigationErrorURL: "https://example.com/",
	};
	return world;
}

for (const code of [-1009, -1202, -1003, -1001, -1100]) {
	test(`the ${code} error page draws a line icon, not an emoji`, async ({ page }) => {
		await bootChrome(page, failedWorld(code));

		const icon = page.locator(".error-page .error-icon");
		await expect(icon.locator("svg")).toBeVisible();
		await expect(icon).toHaveText("");
	});
}

test("a network failure offers the page's saved copy", async ({ page }) => {
	await bootChrome(page, failedWorld(-1001));
	await page.getByRole("button", { name: "Show Saved Copy" }).click();
	await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "showCachedCopy")).toBe(true);
});

test("a cache miss says the saved copy is missing and offers none", async ({ page }) => {
	await bootChrome(page, failedWorld(-1008));
	await expect(page.locator(".error-page .error-title")).toHaveText("No Saved Copy");
	await expect(page.getByRole("button", { name: "Show Saved Copy" })).toHaveCount(0);
});
