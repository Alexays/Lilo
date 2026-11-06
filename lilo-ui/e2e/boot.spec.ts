import { expect, test } from "@playwright/test";
import { bootChrome, glideTo, pressAndLift, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";
import type { FakeHostWorld } from "./fakeHost";

test("seeded spaces and tabs render the sidebar", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const pane = page.locator(".space-pane").nth(0);

	await expect(pane.locator(".tab-list [data-tab-id]")).toHaveCount(3);
	await expect
		.poll(() =>
			pane
				.locator(".tab-list [data-tab-id]")
				.evaluateAll((rows) => rows.map((row) => row.getAttribute("data-tab-id"))),
		)
		.toEqual(["tab-alpha", "tab-beta", "tab-gamma"]);

	await expect(pane.locator(".pinned-list [data-tab-id]")).toHaveCount(1);
	await expect(pane.locator('.pinned-list [data-tab-id="tab-home"]')).toBeVisible();

	await expect(pane.locator(".bookmarked-list .bookmark-tile")).toHaveCount(1);
	await expect(
		pane.locator('.bookmarked-list [aria-label="Marked Wiki"]'),
	).toBeVisible();

	await expect(page.locator("[data-space-dnd-id]")).toHaveCount(2);

	await expect(pane.locator('[data-tab-id="tab-alpha"]')).toHaveAttribute(
		"aria-selected",
		"true",
	);
	await expect(pane.locator('[data-tab-id="tab-beta"]')).toHaveAttribute(
		"aria-selected",
		"false",
	);
});

function worldWith200Tabs(): FakeHostWorld {
	const world = initialWorld();
	const ids = Array.from({ length: 200 }, (_, i) => `tab-m${i}`);
	world.tabsBySpace[SPACE_1] = ids.map((id, i) =>
		tab(id, SPACE_1, { title: `Tab ${i}` }),
	);
	world.treeItemsBySpace[SPACE_1] = ids.map((id, i) =>
		treeItem(id, SPACE_1, i),
	);
	world.activeTabBySpace[SPACE_1] = "tab-m0";
	return world;
}

test("a 200-tab space windows the unpinned list and still reorders", async ({
	page,
}) => {
	await bootChrome(page, worldWith200Tabs());
	const pane = page.locator(".space-pane").nth(0);
	const rows = pane.locator(".tab-list [data-tab-id]");

	// At rest only the window plus buffer is mounted, not all 200 rows.
	const mountedAtRest = await rows.count();
	expect(mountedAtRest).toBeGreaterThan(10);
	expect(mountedAtRest).toBeLessThan(100);
	await expect(pane.locator('[data-tab-id="tab-m199"]')).toHaveCount(0);

	// Scrolling to the bottom renders the last tab.
	const container = pane.locator(".space-scroll");
	await container.evaluate((el) => {
		el.scrollTop = el.scrollHeight;
	});
	await expect(pane.locator('[data-tab-id="tab-m199"]')).toBeVisible();

	// Back to the top, then drag with virtualization active before the gesture;
	// the drag itself de-virtualizes and must still commit the right reorder.
	await container.evaluate((el) => {
		el.scrollTop = 0;
	});
	await expect(pane.locator('[data-tab-id="tab-m1"]')).toBeVisible();
	await pressAndLift(page, '.tab-list [data-tab-id="tab-m0"]');
	// The empty pinned and bookmark drop zones reveal above the list as the drag starts.
	await page.waitForTimeout(250);
	await glideTo(page, '.tab-list [data-tab-id="tab-m1"]', 21);
	await page.mouse.up();

	await expect
		.poll(() =>
			rows.evaluateAll((els) =>
				els.slice(0, 3).map((el) => el.getAttribute("data-tab-id")),
			),
		)
		.toEqual(["tab-m1", "tab-m0", "tab-m2"]);
	const commands = await sentCommands(page);
	const drop = commands.find((c) => c.action === "commitSidebarDrop");
	expect(drop?.payload).toMatchObject({ type: "insert", id: "tab-m0" });

	// After the drop settles the list re-windows: still far fewer than 200 rows.
	await expect.poll(() => rows.count()).toBeLessThan(100);
});

// 100 pinned tabs, then one open folder of 150 tabs as the only unpinned row.
function worldWithLongPinsAndFolder(): FakeHostWorld {
	const world = initialWorld();
	const pins = Array.from({ length: 100 }, (_, i) => `tab-p${i}`);
	const children = Array.from({ length: 150 }, (_, i) => `tab-f${i}`);
	world.tabsBySpace[SPACE_1] = [
		...pins.map((id) => tab(id, SPACE_1, { isPinned: true })),
		...children.map((id) => tab(id, SPACE_1)),
	];
	world.foldersBySpace = {
		[SPACE_1]: [{ id: "folder-big", spaceId: SPACE_1, name: "Big", color: "#4a90d9", isCollapsed: false }],
	};
	world.treeItemsBySpace[SPACE_1] = [
		...pins.map((id, i) => treeItem(id, SPACE_1, i, "pinned")),
		treeItem("folder-big", SPACE_1, 100, "unpinned", "folder"),
		...children.map((id, i) => treeItem(id, SPACE_1, i, "unpinned", "tab", "folder-big")),
	];
	world.activeTabBySpace[SPACE_1] = "tab-p0";
	return world;
}

test("the pinned list and an open folder window their rows too", async ({ page }) => {
	await bootChrome(page, worldWithLongPinsAndFolder(), ".pinned-list [data-tab-id]");
	const pane = page.locator(".space-pane").nth(0);
	const container = pane.locator(".space-scroll");

	await expect(pane.locator('[data-tab-id="tab-p0"]')).toBeVisible();
	expect(await pane.locator(".pinned-list [data-tab-id]").count()).toBeLessThan(60);
	await expect(pane.locator('[data-tab-id="tab-f0"]')).toHaveCount(0);

	// Deep in the folder, the row under the viewport's middle is mounted where the spacers put it.
	await container.evaluate((el) => {
		el.scrollTop = el.scrollHeight * 0.7;
	});
	await expect
		.poll(() =>
			container.evaluate((el) => {
				const rect = el.getBoundingClientRect();
				const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
				return !!hit?.closest("[data-tab-id^='tab-f']");
			}),
		)
		.toBe(true);
	expect(await pane.locator(".folder-contents [data-tab-id]").count()).toBeLessThan(60);

	await container.evaluate((el) => {
		el.scrollTop = el.scrollHeight;
	});
	await expect(pane.locator('[data-tab-id="tab-f149"]')).toBeInViewport();
	// The active tab stays mounted far above the window.
	await expect(pane.locator('[data-tab-id="tab-p0"]')).toHaveCount(1);
});
