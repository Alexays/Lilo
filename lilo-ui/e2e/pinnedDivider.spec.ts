import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1, SPACE_2 } from "./fixtures";

const box = async (page: Page, selector: string) => {
	const rect = await page.locator(selector).first().boundingBox();
	if (!rect) throw new Error(`No bounding box for ${selector}`);
	return rect;
};

test("the divider line runs from the favicon column to the close column", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.locator('.tab-list [data-tab-id="tab-alpha"]').hover();

	const line = await box(page, ".pinned-tab-divider");
	const favicon = await box(page, '.tab-list [data-tab-id="tab-alpha"] .tab-icon');
	const close = await box(page, '.tab-list [data-tab-id="tab-alpha"] .close-btn');
	expect(line.x).toBeCloseTo(favicon.x, 0);
	expect(line.x + line.width).toBeCloseTo(close.x + close.width, 0);
});

test("the divider's Clear button stays clear of the rows around it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.locator('.tab-list [data-tab-id="tab-alpha"]').hover();
	await expect(page.locator(".clear-unpinned")).toHaveCSS("opacity", "1");

	const clear = await box(page, ".clear-unpinned");
	const pinned = await box(page, '.pinned-list [data-tab-id="tab-home"]');
	const first = await box(page, '.tab-list [data-tab-id="tab-alpha"]');

	expect(clear.y).toBeGreaterThanOrEqual(pinned.y + pinned.height + 4);
	expect(clear.y + clear.height).toBeLessThanOrEqual(first.y - 4);
});

test("the divider keeps its size and place while its Space slides in", async ({ page }) => {
	const world = initialWorld();
	world.activeSpaceId = SPACE_2;
	await bootChrome(page, world);
	// The host hydrates the neighbour pane before it slides in.
	await page.evaluate((space) => window.__lilo!.receive({
		event: "browserStateChanged",
		changedSpaceId: space.spaceId,
		activeTabId: space.activeTabId,
		states: [space],
	}), {
		spaceId: SPACE_1,
		activeTabId: world.activeTabBySpace[SPACE_1],
		tabs: world.tabsBySpace[SPACE_1],
		folders: [],
		treeItems: world.treeItemsBySpace[SPACE_1],
	});
	await expect(page.locator(".space-pane").first().locator('[data-tab-id="tab-alpha"]')).toBeAttached();

	// One sample per frame: the divider's offset in its pane and its height.
	const sampling = page.evaluate(() => new Promise<string[]>((resolve) => {
		const samples: string[] = [];
		const start = performance.now();
		const sample = () => {
			const pane = document.querySelectorAll(".space-pane")[0];
			const shell = pane?.querySelector(".pinned-tab-divider-shell");
			const rect = shell?.getBoundingClientRect();
			samples.push(rect ? `${rect.top - pane.getBoundingClientRect().top}:${rect.height}` : "none");
			if (performance.now() - start < 1200) requestAnimationFrame(sample);
			else resolve(samples);
		};
		requestAnimationFrame(sample);
	}));
	await page.locator(`[data-space-dnd-id="${SPACE_1}"] .space-drag-wrapper`).click();
	const samples = await sampling;

	expect(new Set(samples).size, samples.join(" ")).toBe(1);
});

test("the divider line holds still when the last tab Clear could archive closes", async ({ page }) => {
	const world = initialWorld();
	const kept = new Set(["tab-home", "tab-wiki", "tab-alpha"]);
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].filter((tab) => kept.has(tab.id));
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].filter((item) => kept.has(item.itemId));
	await bootChrome(page, world);
	await page.locator('.tab-list [data-tab-id="tab-alpha"]').hover();

	const sampling = page.evaluate(() => new Promise<number[]>((resolve) => {
		const tops: number[] = [];
		const start = performance.now();
		const sample = () => {
			tops.push(document.querySelector(".pinned-tab-divider")!.getBoundingClientRect().top);
			if (performance.now() - start < 800) requestAnimationFrame(sample);
			else resolve(tops);
		};
		requestAnimationFrame(sample);
	}));
	await page.locator('.tab-list [data-tab-id="tab-alpha"] .close-btn').click();
	const tops = await sampling;

	await expect(page.locator('.tab-list [data-tab-id="tab-alpha"]')).toHaveCount(0);
	expect(new Set(tops).size, tops.join(" ")).toBe(1);
});
