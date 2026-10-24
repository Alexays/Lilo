import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

// Script-driven animations (Svelte transitions, FLIP moves) that would still take time on screen.
function runningAnimations(page: Page): Promise<string[]> {
	return page.evaluate(() => document.getAnimations()
		.filter((animation) => Number(animation.effect?.getComputedTiming().duration ?? 0) > 1)
		.map((animation) => {
			const target = (animation.effect as KeyframeEffect | null)?.target;
			return `${target?.className ?? "?"} ${animation.effect?.getComputedTiming().duration}ms`;
		}));
}

test.use({ reducedMotion: "reduce" });

test("a tab starting to load swaps its icon without motion", async ({ page }) => {
	const world = initialWorld();
	await bootChrome(page, world);
	const alpha = world.tabsBySpace[SPACE_1][0];

	await page.evaluate((tab) => window.__lilo!.receive({
		event: "browserStatePatch",
		operations: [{ kind: "tabUpdated", spaceId: tab.spaceId, activeTabId: tab.id, tab: { ...tab, isLoading: true } }],
	}), alpha);
	await expect(page.locator('[data-tab-id="tab-alpha"] .tab-loader')).toBeVisible();

	expect(await runningAnimations(page)).toEqual([]);
});

test("moving a tab by keyboard reorders without motion", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.getByRole("treeitem", { name: /^Alpha Docs/ }).focus();

	await page.keyboard.press("Alt+ArrowDown");
	await expect(page.getByRole("treeitem", { name: /^Alpha Docs/ })).toBeFocused();

	expect(await runningAnimations(page)).toEqual([]);
});
