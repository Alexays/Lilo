import { expect, test, type Page } from "@playwright/test";
import { bootChrome, glideTo, pressAndLift, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1, SPACE_2 } from "./fixtures";

const tile = (page: Page, spaceId: string) => page.locator(`[data-space-dnd-id="${spaceId}"] .space-drag-wrapper`);

const createProfile = (page: Page, id: string, color: string) =>
	page.evaluate(([id, color]) => window.__lilo!.receive({
		event: "profileCreated", id, name: id, isDefault: false, color,
	}), [id, color]);

test("space tiles wear their profile color only once a second profile exists", async ({ page }) => {
	const world = initialWorld();
	world.spaces[1].profileId = "profile-2";
	await bootChrome(page, world);
	await createProfile(page, "profile-1", "#f1a7a5");
	await expect(tile(page, SPACE_1)).not.toHaveClass(/tinted/);

	await createProfile(page, "profile-2", "#b39df4");
	await expect(tile(page, SPACE_1)).toHaveClass(/tinted/);
	await expect(tile(page, SPACE_2)).toHaveAttribute("style", /--space-tint: #b39df4/);

	await page.evaluate(() => window.__lilo!.receive({
		event: "spaceCreated", id: "private", name: "Private", icon: "P", color: "#3f4656", profileId: "profile-1", isPrivate: true, sortOrder: 2,
	}));
	await expect(tile(page, "private")).toBeVisible();
	await expect(tile(page, "private")).not.toHaveClass(/tinted/);
});

test("an acting agent glows behind its Space and a waiting terminal is the bar's only dot", async ({ page }) => {
	const world = initialWorld();
	await bootChrome(page, world);
	// The Agents space borrows profile-1, so it keeps that profile's tint.
	await page.evaluate(([spaceId]) => window.__lilo!.receiveBatch([
		{ event: "profileCreated", id: "profile-1", name: "Personal", isDefault: true, color: "#f1a7a5" },
		{ event: "profileCreated", id: "profile-2", name: "Work", isDefault: false, color: "#b39df4" },
		{
			event: "agentActivity",
			clients: [{ name: "agent", busy: true, actingTabIds: [], spaceIds: [spaceId] }],
			agentsSpaceIds: [spaceId],
			agentsProfileId: "agents-profile",
			hiddenAgentsSpaceIds: [],
		},
	]), [SPACE_2]);
	await expect(tile(page, SPACE_2)).toHaveAttribute("data-activity", "agent");
	await expect(tile(page, SPACE_2)).toHaveClass(/tinted/);
	await expect(page.locator(".space-attention-dot")).toHaveCount(0);

	await page.evaluate(([spaceId]) => window.__lilo!.receive({
		event: "terminalActivity",
		terminals: [{
			tabId: "term", title: "zsh", command: "", state: "idle", awaitingInputSince: 1, startedAt: 0,
			exitCode: 0, duration: 0, gitBranch: "", spaceId, spaceName: "Play",
		}],
	}), [SPACE_2]);
	await expect(tile(page, SPACE_2)).toHaveAttribute("data-activity", "attention");
	await expect(page.locator(".space-attention-dot")).toHaveCount(1);
	await expect(page.locator(`[data-space-dnd-id="${SPACE_2}"] .space-attention-dot`)).toHaveCount(1);
});

test("a terminal that only runs leaves its Space's tile quiet", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(([spaceId]) => window.__lilo!.receive({
		event: "terminalActivity",
		terminals: [{
			tabId: "term", title: "npm run dev", command: "npm run dev", state: "busy", awaitingInputSince: 0, startedAt: 1,
			exitCode: 0, duration: 0, gitBranch: "", spaceId, spaceName: "Play",
		}],
	}), [SPACE_2]);
	await expect(tile(page, SPACE_2)).not.toHaveAttribute("data-activity");
	await expect(page.locator(".space-attention-dot")).toHaveCount(0);
});

test("the Space tiles fade out on the sides they scroll toward", async ({ page }) => {
	const world = initialWorld();
	for (let i = 3; i <= 10; i++) {
		world.spaces.push({ ...world.spaces[1], id: `space-${i}`, name: `Space ${i}`, icon: String(i), sortOrder: i });
	}
	await bootChrome(page, world);
	const scroller = page.locator(".space-icons-scroller");
	await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "200px"));
	await expect(scroller).toHaveClass(/fade-end/);
	await expect(scroller).not.toHaveClass(/fade-start/);
	expect(await scroller.evaluate((el) => getComputedStyle(el).maskImage)).not.toBe("none");

	await scroller.evaluate((el) => { el.scrollLeft = el.scrollWidth; });
	await expect(scroller).toHaveClass(/fade-start/);
	await expect(scroller).not.toHaveClass(/fade-end/);
});

test("an inactive Space tile stays legible while the active one keeps its highlight", async ({ page }) => {
	await bootChrome(page, initialWorld());
	// Two tiles fit: nothing to fade.
	await expect(page.locator(".space-icons-scroller")).not.toHaveClass(/fade/);
	const button = (spaceId: string) => page.locator(`[data-space-dnd-id="${spaceId}"] .space-icon-btn`);

	expect(Number(await button(SPACE_2).evaluate((el) => getComputedStyle(el).opacity))).toBeGreaterThanOrEqual(0.7);
	await expect(button(SPACE_1)).toHaveCSS("opacity", "1");
	expect(await button(SPACE_1).evaluate((el) => getComputedStyle(el, "::before").opacity)).toBe("1");
	expect(await button(SPACE_2).evaluate((el) => getComputedStyle(el, "::before").opacity)).toBe("0");
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("the move hint keeps a margin inside a narrow sidebar", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "200px"));
		await pressAndLift(page, '.tab-list [data-tab-id="tab-beta"]');
		await glideTo(page, ".new-tab-row");
		const hint = page.locator(".space-move-hint");
		await expect(hint).toBeVisible();
		await page.waitForTimeout(400);

		const box = (await hint.boundingBox())!;
		const sidebar = (await page.locator(".sidebar").boundingBox())!;
		expect(box.x - sidebar.x).toBeGreaterThanOrEqual(8);
		expect(sidebar.x + sidebar.width - (box.x + box.width)).toBeGreaterThanOrEqual(8);
		await page.mouse.up();
	});
});

test("the Space tiles sit centered between two equal slots and hold still when downloads appear", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const tiles = () => Promise.all([SPACE_1, SPACE_2].map(async (id) => (await tile(page, id).boundingBox())!.x));
	const slots = async () => Promise.all([".bottom-side:not(.end)", ".bottom-side.end"].map(async (s) => (await page.locator(s).boundingBox())!));

	const before = await tiles();
	const [left, right] = await slots();
	expect(left.width).toBe(right.width);
	const bar = (await page.locator(".bottom-bar").boundingBox())!;
	expect(left.x - bar.x).toBeCloseTo(bar.x + bar.width - (right.x + right.width), 0);

	await page.evaluate(() => window.__lilo!.receive({
		event: "downloadUpdated", id: 1, url: "https://example.com/a.zip", filename: "a.zip", state: "inProgress",
		bytesReceived: 10, totalBytes: 100, startedAt: 1, fileMissing: false, source: "wk",
	}));
	await expect(page.locator(".download-btn-wrap")).toBeVisible();
	expect(await tiles()).toEqual(before);
	const [leftWithDownload, rightWithDownload] = await slots();
	expect(leftWithDownload.width).toBe(rightWithDownload.width);
});

test("with more Spaces than the bar holds, every tile stays reachable and clear of the add button", async ({ page }) => {
	const world = initialWorld();
	for (let i = 3; i <= 10; i++) {
		world.spaces.push({ ...world.spaces[1], id: `space-${i}`, name: `Space ${i}`, icon: String(i), sortOrder: i });
	}
	await bootChrome(page, world);
	await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "200px"));

	const add = (await page.locator(".bottom-side.end .bottom-btn").boundingBox())!;
	const addIsOnTop = await page.evaluate(
		([x, y]) => document.elementFromPoint(x, y)?.closest(".bottom-btn") !== null,
		[add.x + add.width / 2, add.y + add.height / 2],
	);
	expect(addIsOnTop).toBe(true);

	for (const spaceId of ["space-10", SPACE_2]) {
		await page.locator(`[data-space-dnd-id="${spaceId}"] .space-icon-btn`).click();
		await expect.poll(async () => (await sentCommands(page)).some(
			(command) => command.action === "switchSpace" && command.payload.id === spaceId,
		)).toBe(true);
	}

	// A switch from the host (a ⌃ shortcut) brings the tile it lands on back into view.
	await page.evaluate(() => window.__lilo!.receive({
		event: "browserStateChanged",
		changedSpaceId: "space-10",
		profileId: "profile-1",
		activeTabId: "",
		states: [{ spaceId: "space-10", activeTabId: "", tabs: [], folders: [], treeItems: [] }],
	}));
	await expect(page.locator(`[data-space-dnd-id="space-10"] .space-icon-btn`)).toBeInViewport({ ratio: 1 });
});
