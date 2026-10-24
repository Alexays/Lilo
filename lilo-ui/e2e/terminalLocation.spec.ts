import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

async function bootTerminal(page: Page, cwd: string): Promise<void> {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1] = [
		...world.tabsBySpace[SPACE_1],
		tab("tab-shell", SPACE_1, { title: "storefront", url: "", kind: "terminal", cwd, gitBranch: "feature/checkout-redesign", diffAdded: 77 }),
	];
	world.treeItemsBySpace[SPACE_1] = [...world.treeItemsBySpace[SPACE_1], treeItem("tab-shell", SPACE_1, 5)];
	world.activeTabBySpace[SPACE_1] = "tab-shell";
	await bootChrome(page, world);
	await page.locator(".location-name").waitFor();
}

test("a long folder path shrinks, then drops its middle folders, and keeps its name whole", async ({ page }) => {
	await bootTerminal(page, "/Users/me/Projects/acme/storefront");

	const path = page.locator(".location-path");
	await expect(page.locator(".location-name")).toHaveText("storefront");
	// Nothing clipped: what is left of the path fits as it is drawn.
	await expect.poll(() => path.evaluate((el) => el.scrollWidth <= el.clientWidth + 1)).toBe(true);
	await expect(page.locator(".location-parent")).toHaveText(/^~\/(Projects\/|…\/)?(acme\/)?$/);
});

test("a short path keeps the bar's own size", async ({ page }) => {
	await bootTerminal(page, "/Users/me/code");

	await expect(page.locator(".location-parent")).toHaveText("~/");
	expect(await page.locator(".location-path").getAttribute("style")).toBeFalsy();
});
