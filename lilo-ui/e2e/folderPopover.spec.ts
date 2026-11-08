import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands, type FakeHostWorld } from "./fakeHost";
import { folderWorld, SPACE_1 } from "./fixtures";
import { treeItem } from "../src/stores/testFixtures";

// folderWorld with tab-beta and tab-gamma moved into the collapsed "Shut", and a locked "Vault"
// holding a tab of its own.
function popoverWorld(): FakeHostWorld {
	const world = folderWorld();
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].map((tab) =>
		tab.id === "tab-beta" ? { ...tab, url: "https://mail.example.com/inbox" }
		: tab.id === "tab-gamma" ? { ...tab, url: "https://news.example.org/today" }
		: tab);
	world.foldersBySpace![SPACE_1].push({ id: "folder-vault", spaceId: SPACE_1, name: "Vault", color: "#4a90d9", isCollapsed: true, isLocked: true });
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].map((item) =>
		item.itemId === "tab-beta" || item.itemId === "tab-gamma" ? { ...item, parentFolderId: "folder-shut" } : item);
	world.treeItemsBySpace[SPACE_1].push(treeItem("folder-vault", SPACE_1, 8, "unpinned", "folder"));
	return world;
}

const folderRow = (page: Page, name: string) => page.locator(".folder-row", { hasText: name });
const popover = (page: Page) => page.locator(".folder-popover");

test("a closed folder shows its tabs beside the sidebar on hover, filters them and switches on click", async ({ page }) => {
	await bootChrome(page, popoverWorld(), ".folder-row");
	const row = folderRow(page, "Shut");
	await row.hover();

	await expect(popover(page)).toBeVisible();
	await expect(popover(page).locator(".float-row .title")).toHaveText(["Beta Mail", "Gamma News"]);
	await expect(popover(page).locator(".float-row .host")).toHaveText(["mail.example.com", "news.example.org"]);
	// The hover leaves the keyboard where it was.
	await expect(popover(page).locator("input")).not.toBeFocused();
	const box = (await popover(page).boundingBox())!;
	const sidebar = (await page.locator(".sidebar-layout").boundingBox())!;
	expect(box.x).toBeGreaterThan(sidebar.x + sidebar.width);
	expect(box.y).toBeCloseTo((await row.boundingBox())!.y, 0);

	const field = popover(page).locator("input");
	await field.click();
	await expect(field).toBeFocused();
	await page.keyboard.type("news");
	await expect(popover(page).locator(".float-row")).toHaveCount(1);

	await popover(page).locator(".float-row", { hasText: "Gamma News" }).click();
	await expect(popover(page)).toHaveCount(0);
	const switches = (await sentCommands(page)).filter((c) => c.action === "switchTab");
	expect(switches.at(-1)?.payload).toEqual({ id: "tab-gamma" });
});

test("the popover stays up on the way over from the row and closes once the pointer leaves both", async ({ page }) => {
	await bootChrome(page, popoverWorld(), ".folder-row");
	await folderRow(page, "Shut").hover();
	await expect(popover(page)).toBeVisible();

	const box = (await popover(page).boundingBox())!;
	await page.mouse.move(box.x + box.width / 2, box.y + 60, { steps: 6 });
	await page.waitForTimeout(400);
	await expect(popover(page)).toBeVisible();

	await page.mouse.move(box.x + box.width + 100, box.y + box.height + 100);
	await expect(popover(page)).toHaveCount(0);
});

test("an open or a locked folder shows no popover", async ({ page }) => {
	await bootChrome(page, popoverWorld(), ".folder-row");
	await folderRow(page, "Docs").hover();
	await page.waitForTimeout(700);
	await expect(popover(page)).toHaveCount(0);

	await folderRow(page, "Vault").hover();
	await page.waitForTimeout(700);
	await expect(popover(page)).toHaveCount(0);
});

test("Space on a closed folder opens the popover with its field focused, the arrows pick a tab", async ({ page }) => {
	await bootChrome(page, popoverWorld(), ".folder-row");
	const row = folderRow(page, "Shut");
	await row.focus();
	await page.keyboard.press("Space");

	await expect(popover(page).locator("input")).toBeFocused();
	await expect(row).toHaveAttribute("aria-expanded", "false");
	await page.keyboard.press("Escape");
	await expect(popover(page)).toHaveCount(0);
	await expect(row).toBeFocused();

	await page.keyboard.press("Space");
	await page.keyboard.press("ArrowDown");
	await page.keyboard.press("ArrowDown");
	await expect(popover(page).locator(".float-row").nth(1)).toBeFocused();
	await page.keyboard.press("Enter");
	const switches = (await sentCommands(page)).filter((c) => c.action === "switchTab");
	expect(switches.at(-1)?.payload).toEqual({ id: "tab-gamma" });
});

test("with the tabs on the right the popover opens on the sidebar's left", async ({ page }) => {
	await bootChrome(page, { ...popoverWorld(), tabPosition: "right" }, ".folder-row");
	await folderRow(page, "Shut").hover();

	const box = (await popover(page).boundingBox())!;
	const sidebar = (await page.locator(".sidebar-layout").boundingBox())!;
	expect(box.x + box.width).toBeLessThan(sidebar.x);
});
