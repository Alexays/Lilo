import { expect, test, type Page } from "@playwright/test";
import { bootChrome, type FakeHostWorld } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";
import type {
	BridgeSpaceBrowserStatePayload,
	BridgeTabSnapshot,
} from "../src/lib/bridge/protocol";

// What a big Arc import leaves in one space: 20 favorites, 40 pinned folders of 5 closed tabs
// (the first one expanded), 2 split folders and 1,700 unpinned tabs, all with non-ASCII titles.
const FAVORITES = 20;
const FOLDERS = 40;
const FOLDER_TABS = 5;
const UNPINNED = 1700;

function importedSpace(spaceId: string, unpinned: number, withFolders: boolean): BridgeSpaceBrowserStatePayload {
	const state: BridgeSpaceBrowserStatePayload = { spaceId, activeTabId: "open-0", tabs: [], folders: [], treeItems: [] };
	const add = (id: string, section: "bookmarked" | "pinned" | "unpinned", parent: string | null, overrides: Partial<BridgeTabSnapshot>) => {
		state.tabs.push(tab(id, spaceId, overrides));
		state.treeItems.push(treeItem(id, spaceId, state.treeItems.length, section, "tab", parent));
	};
	const folder = (id: string, section: "pinned" | "unpinned", name: string, extra: object = {}) => {
		state.folders.push({ id, spaceId, name, color: "#6d5ae6", isCollapsed: id !== "folder-0", ...extra });
		state.treeItems.push(treeItem(id, spaceId, state.treeItems.length, section, "folder"));
	};
	if (withFolders) {
		for (let i = 0; i < FAVORITES; i++) {
			add(`fav-${i}`, "bookmarked", null, { title: `Favori ${i} ☕`, isBookmarked: true, isClosed: true });
		}
		for (let f = 0; f < FOLDERS; f++) {
			folder(`folder-${f}`, "pinned", `Projets / 日本語 ${f}`);
			for (let t = 0; t < FOLDER_TABS; t++) {
				add(`folder-${f}-tab-${t}`, "pinned", `folder-${f}`, { title: `Doc ${f}.${t} 🎉`, isPinned: true, isClosed: true });
			}
		}
		for (let s = 0; s < 2; s++) {
			const [a, b] = [`split-${s}-a`, `split-${s}-b`];
			folder(`split-${s}`, "unpinned", "", {
				isCollapsed: false,
				isSplit: true,
				splitLayout: { vertical: s === 1, first: { tabId: a }, second: { tabId: b } },
			});
			add(a, "unpinned", `split-${s}`, { title: `Pane ${a}` });
			add(b, "unpinned", `split-${s}`, { title: `Pane ${b}` });
		}
	}
	for (let i = 0; i < unpinned; i++) add(`open-${i}`, "unpinned", null, { title: `Onglet ${i} Ünïcødé` });
	return state;
}

function tenSpaces(): FakeHostWorld {
	const world = initialWorld();
	for (let i = world.spaces.length; i < 10; i++) {
		world.spaces.push({ ...world.spaces[0], id: `space-${i + 1}`, name: `Space ${i + 1}`, sortOrder: i });
	}
	return world;
}

// Pushes `state` as the host does after an import; resolves once `doneSelector` shows, with the
// elapsed time and the longest main-thread task seen meanwhile.
function pushState(page: Page, state: BridgeSpaceBrowserStatePayload, doneSelector: string) {
	return page.evaluate(async ({ state, doneSelector }) => {
		let longestTask = 0;
		const observer = new PerformanceObserver((list) => {
			for (const entry of list.getEntries()) longestTask = Math.max(longestTask, entry.duration);
		});
		observer.observe({ type: "longtask" });
		const start = performance.now();
		window.__lilo!.receive({ event: "browserStateChanged", changedSpaceId: state.spaceId, activeTabId: state.activeTabId, states: [state] });
		const pane = document.querySelectorAll(".space-pane")[0];
		while (!pane.querySelector(doneSelector)) await new Promise((resolve) => requestAnimationFrame(resolve));
		const elapsed = performance.now() - start;
		await new Promise((resolve) => setTimeout(resolve, 100));
		observer.disconnect();
		return { elapsed, longestTask };
	}, { state, doneSelector });
}

// Median time from a one-tab title patch to the new title on screen, over a few renames.
function renameCost(page: Page, seed: BridgeTabSnapshot) {
	return page.evaluate(async (seed) => {
		const samples: number[] = [];
		for (let i = 0; i < 7; i++) {
			const title = `Renamed ${seed.id} ${i}`;
			const start = performance.now();
			window.__lilo!.receive({
				event: "browserStatePatch",
				operations: [{ kind: "tabUpdated", spaceId: seed.spaceId, activeTabId: "open-0", tab: { ...seed, title } }],
			});
			const row = document.querySelectorAll(".space-pane")[0].querySelector(`[data-tab-id="${seed.id}"]`);
			while (!row?.textContent?.includes(title)) await new Promise((resolve) => requestAnimationFrame(resolve));
			samples.push(performance.now() - start);
		}
		return samples.sort((a, b) => a - b)[3];
	}, seed);
}

test("a 2,000-tab imported space renders windowed, in order, and keeps a tab patch cheap", async ({ page }) => {
	await bootChrome(page, tenSpaces());

	// Reference: the same patch on a 10-tab space.
	const small = importedSpace(SPACE_1, 10, false);
	await pushState(page, small, '[data-tab-id="open-9"]');
	const smallPatch = await renameCost(page, small.tabs[5]);

	const big = importedSpace(SPACE_1, UNPINNED, true);
	const render = await pushState(page, big, '[data-tab-id="folder-0-tab-4"]');
	const pane = page.locator(".space-pane").nth(0);

	await expect(pane.locator(".bookmark-tile")).toHaveCount(FAVORITES);
	const titles = await pane.locator(".folder-title").allTextContents();
	expect(titles.filter((name) => name.startsWith("Projets"))).toEqual(
		Array.from({ length: FOLDERS }, (_, f) => `Projets / 日本語 ${f}`),
	);
	// Only the expanded folder shows its tabs, in order.
	await expect(pane.locator('[data-tab-id^="folder-0-tab-"]')).toHaveCount(FOLDER_TABS);
	await expect(pane.locator('[data-tab-id^="folder-1-tab-"]')).toHaveCount(0);
	expect(await pane.locator('[data-tab-id^="folder-0-tab-"]').evaluateAll((rows) => rows.map((row) => row.getAttribute("data-tab-id"))))
		.toEqual(Array.from({ length: FOLDER_TABS }, (_, t) => `folder-0-tab-${t}`));

	// Scrolling mounts the rows it reaches: the splits at the top of the list, then the last tab.
	await pane.locator('[data-tab-id="open-0"]').scrollIntoViewIfNeeded();
	await expect(pane.locator(".split-row")).toHaveCount(2);
	expect(await pane.locator('.split-row [data-tab-id]').evaluateAll((rows) => rows.map((row) => row.getAttribute("data-tab-id"))))
		.toEqual(["split-0-a", "split-0-b", "split-1-a", "split-1-b"]);
	// The unpinned list is windowed: a screenful of rows, not 1,700.
	const mountedOpen = await pane.locator('[data-tab-id^="open-"]').count();
	expect(mountedOpen).toBeGreaterThan(5);
	expect(mountedOpen).toBeLessThan(200);

	// A few trackpad frames inside one window step re-render nothing: the same rows stay mounted.
	const windowRows = () => pane.locator('[data-tab-id^="open-"]').evaluateAll((rows) => rows.map((row) => row.getAttribute("data-tab-id")).join());
	await pane.locator(".space-scroll").evaluate((scroller) => {
		// Lands the unpinned list's offset 10px past a 160px window step.
		const lists = scroller.querySelectorAll(".tab-list");
		const offset = scroller.getBoundingClientRect().top - lists[lists.length - 1].getBoundingClientRect().top + 400;
		scroller.scrollTop += 400 + Math.ceil(offset / 160) * 160 - offset + 10;
	});
	await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
	const settled = await windowRows();
	for (let i = 0; i < 4; i++) {
		await pane.locator(".space-scroll").evaluate((scroller) => { scroller.scrollTop += 20; });
		await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
	}
	expect(await windowRows()).toBe(settled);

	const bigPatch = await renameCost(page, big.tabs.find((t) => t.id === "open-3")!);

	await pane.locator(".space-scroll").evaluate((scroller) => { scroller.scrollTop = scroller.scrollHeight; });
	await expect(pane.locator(`[data-tab-id="open-${UNPINNED - 1}"]`)).toHaveCount(1);

	// Generous, load-tolerant guards: no freeze on the push, and a one-tab patch must not scale
	// with the space's 2,000 rows.
	expect(render.longestTask).toBeLessThan(1000);
	expect(bigPatch).toBeLessThan(smallPatch * 10 + 100);
});
