import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1, SPACE_2 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

test("clicking a space in the bottom bar switches the sidebar to it", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());
	const targetPane = page.locator(".space-pane").nth(1);

	// The second space is seeded but not hydrated until the switch echo arrives.
	await expect(targetPane.locator(".tab-list [data-tab-id]")).toHaveCount(0);

	await page.locator(`[data-space-dnd-id="${SPACE_2}"] .space-icon-btn`).click();

	await expect(
		targetPane.locator('.tab-list [data-tab-id="tab-zeta"]'),
	).toHaveCount(1);
	await expect(targetPane.locator('[data-tab-id="tab-zeta"]')).toHaveAttribute(
		"aria-selected",
		"true",
	);
	const commands = await sentCommands(page);
	expect(
		commands.find((c) => c.action === "switchSpace")?.payload,
	).toMatchObject({ id: SPACE_2 });
});

test("closing a tab removes its row; restoring brings it back", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());
	const activePane = page.locator(".space-pane").nth(0);
	const row = activePane.locator('.tab-list [data-tab-id="tab-beta"]');

	// Click activates (and focuses) the row, then Delete closes it.
	await row.click();
	await expect(row).toHaveAttribute("aria-selected", "true");
	await row.press("Delete");

	await expect(activePane.locator(".tab-list [data-tab-id]")).toHaveCount(2);
	await expect(row).toHaveCount(0);

	// Restore through the real path: the command bar's Reopen Closed Tab command posts
	// restoreClosedTab, and the host reducer re-adds the tab and echoes.
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").pressSequentially("reopen");
	await page
		.locator(".command-bar-result", { hasText: "Reopen Closed Tab" })
		.click();
	await expect(
		activePane.locator('.tab-list [data-tab-id="tab-beta"]'),
	).toHaveCount(1);
	await expect(
		activePane.locator('[data-tab-id="tab-beta"]'),
	).toHaveAttribute("aria-selected", "true");
});

test("the close button takes no room until the row is hovered", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	// tab-beta is inactive, so its close button is hidden until hover.
	const row = page.locator('.tab-list [data-tab-id="tab-beta"]');
	const title = row.locator(".tab-title");
	const idleWidth = (await title.boundingBox())!.width;

	await row.hover();
	await expect(row.locator(".close-btn")).toHaveClass(/visible/);

	// Polled: the button expands through a width transition.
	await expect
		.poll(async () => (await title.boundingBox())!.width)
		.toBeLessThan(idleWidth);
});

test("the terminal button beside New Tab opens a terminal", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const line = page.locator(".space-pane").nth(0).locator(".new-tab-line");

	await line.locator(".new-terminal-button").click();

	const commands = await sentCommands(page);
	expect(commands.some((c) => c.action === "newTerminal")).toBe(true);
	expect(commands.some((c) => c.action === "createTab")).toBe(false);
});

test("the New Tab row stays while a terminal is the active tab", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1] = [
		...world.tabsBySpace[SPACE_1],
		tab("tab-shell", SPACE_1, { title: "~", url: "", kind: "terminal" }),
	];
	world.treeItemsBySpace[SPACE_1] = [...world.treeItemsBySpace[SPACE_1], treeItem("tab-shell", SPACE_1, 5)];
	world.activeTabBySpace[SPACE_1] = "tab-shell";
	await bootChrome(page, world);

	await expect(page.locator(".space-pane").nth(0).locator(".new-tab-line .new-tab-row")).toBeVisible();
});

test("the terminal button beside New Tab sits on the close buttons' column", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const center = async (selector: string) => {
		const box = (await page.locator(selector).first().boundingBox())!;
		return box.x + box.width / 2;
	};

	expect(await center(".new-terminal-button")).toBeCloseTo(await center('.tab-item.active .close-btn'), 0);
});

test("Tab never lands on the sidebar while a panel covers it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").first().waitFor();

	for (let i = 0; i < 40; i++) {
		await page.keyboard.press("Tab");
		expect(await page.evaluate(() => document.activeElement?.closest(".sidebar-layout") !== null)).toBe(false);
	}
});
