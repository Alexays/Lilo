import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands, type FakeHostWorld } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

const sidebarBackground = (page: Page) =>
	page.evaluate(() => document.documentElement.style.getPropertyValue("--sidebar-bg").trim());

const lastCommand = async (page: Page, action: string) =>
	(await sentCommands(page)).filter((command) => command.action === action).at(-1)?.payload;

const fromTab = (page: Page) => page.getByRole("button", { name: "Color of the active tab", exact: true });
const fromWallpaper = (page: Page) => page.getByRole("button", { name: "Color of your wallpaper", exact: true });

async function openAppearance(page: Page): Promise<void> {
	await page.evaluate((id) => window.__lilo!.receive({ event: "openSpaceEditor", id }), SPACE_1);
	await expect(page.locator(".editor-panel")).toBeVisible();
	await page.getByRole("button", { name: "Appearance" }).click();
	await expect(page.getByRole("dialog", { name: "Appearance" })).toBeVisible();
}

// 19:00, the evening: a Space following the time is warmer than its base color.
async function bootInTheEvening(page: Page, world: FakeHostWorld): Promise<void> {
	await page.clock.install({ time: new Date(2026, 9, 25, 19, 0) });
	await bootChrome(page, world);
}

function worldOnAColorfulSite(): FakeHostWorld {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1][0] = tab("tab-alpha", SPACE_1, { title: "Alpha Docs", faviconDominantColor: "#e5484d" });
	return world;
}

test("each color source and material previews on the whole chrome, and Save sends them", async ({ page }) => {
	await bootInTheEvening(page, worldOnAColorfulSite());
	const fixed = await sidebarBackground(page);
	await openAppearance(page);

	await expect(fromTab(page)).toHaveAttribute("aria-pressed", "false");

	await page.getByRole("button", { name: "Change with the time of day" }).click();
	await expect.poll(() => sidebarBackground(page)).not.toBe(fixed);
	// The base color is still the user's to pick while it follows the day.
	const evening = await sidebarBackground(page);
	// Past the tab and the wallpaper, the first color.
	await page.locator(".swatches .swatch").nth(2).click();
	await expect.poll(() => sidebarBackground(page)).not.toBe(evening);

	// The active tab's site brings the color: the title says so, and the day has nothing to change.
	await fromTab(page).click();
	await expect(fromTab(page)).toHaveAttribute("aria-pressed", "true");
	await expect(page.locator(".appearance-card .name")).toHaveText("Color of the active tab");
	await expect(page.getByRole("button", { name: "Change with the time of day" })).toHaveCount(0);
	await expect.poll(() => sidebarBackground(page)).not.toBe(evening);
	const tinted = await sidebarBackground(page);

	await fromWallpaper(page).click();
	await expect.poll(() => lastCommand(page, "setWallpaperColorWatch")).toEqual({ enabled: true });
	await page.evaluate(() => window.__lilo!.receive({ event: "wallpaperColorChanged", color: "#2f9e8f", thumbnail: "data:image/jpeg;base64,AAAA" }));
	await expect.poll(() => sidebarBackground(page)).not.toBe(tinted);
	// The preview stands the window on the wallpaper itself.
	expect(await page.locator(".desk").evaluate((node) => getComputedStyle(node).backgroundImage)).toContain("data:image/jpeg");

	// A color takes back from Lilo's pick.
	await page.locator(".swatches .swatch").nth(4).click();
	await expect(fromWallpaper(page)).toHaveAttribute("aria-pressed", "false");
	await fromWallpaper(page).click();
	await page.getByRole("radiogroup", { name: "Material" }).getByRole("radio", { name: "Grain" }).click();
	await expect.poll(() => page.evaluate(() => document.documentElement.dataset.material)).toBe("grain");

	await page.keyboard.press("Escape");
	await expect(page.getByRole("dialog", { name: "Appearance" })).toHaveCount(0);
	await expect(page.locator(".editor-panel")).toBeVisible();
	await page.keyboard.press("Meta+Enter");
	await expect(page.locator(".editor-panel")).toHaveCount(0);
	expect(await lastCommand(page, "updateSpace")).toMatchObject({ id: SPACE_1, colorMode: "wallpaper", material: "grain" });
	// Back on the saved fixed Space (the host has not echoed the change): the wallpaper is no longer watched.
	await expect.poll(() => lastCommand(page, "setWallpaperColorWatch")).toEqual({ enabled: false });
});

test("a saved Space following the time lights the chrome without the editor open", async ({ page }) => {
	const world = initialWorld();
	const fixed = { ...world.spaces[0] };
	world.spaces[0] = { ...fixed, colorMode: "time" };
	await bootInTheEvening(page, world);
	const evening = await sidebarBackground(page);
	await page.evaluate((space) => window.__lilo!.receive({ event: "spaceUpdated", ...space }), fixed);
	await expect.poll(() => sidebarBackground(page)).not.toBe(evening);
});

test("the onboarding's appearance step sets the current Space's color and material", async ({ page }) => {
	const world: FakeHostWorld = {
		spaces: [{ id: "space-home", name: "Home", icon: "H", color: "#5865f2", profileId: "profile-1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: "space-home",
		activeTabBySpace: { "space-home": "tab-blank" },
		tabsBySpace: { "space-home": [tab("tab-blank", "space-home", { url: "", title: "" })] },
		treeItemsBySpace: { "space-home": [treeItem("tab-blank", "space-home", 0)] },
	};
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "onboardingState", show: true, step: 4, usage: "browse" }));
	await expect(fromTab(page)).toHaveAttribute("aria-pressed", "false");

	await page.getByRole("button", { name: "Change with the time of day" }).click();
	await expect.poll(() => lastCommand(page, "updateSpace")).toEqual({ id: "space-home", colorMode: "time" });
	await page.evaluate(() => window.__lilo!.receive({ event: "spaceUpdated", ...{ id: "space-home", name: "Home", icon: "H", color: "#5865f2", profileId: "profile-1", isPrivate: false, sortOrder: 0, colorMode: "time" } }));
	await expect(page.getByRole("button", { name: "Change with the time of day" })).toHaveAttribute("aria-pressed", "true");

	await page.getByRole("radiogroup", { name: "Material" }).getByRole("radio", { name: "Glass" }).click();
	await expect.poll(() => lastCommand(page, "updateSpace")).toEqual({ id: "space-home", material: "glass" });

	// The color is the user's here too, sent at once.
	await page.locator(".swatches .swatch").nth(2).click();
	await expect.poll(() => lastCommand(page, "updateSpace")).toMatchObject({ id: "space-home", color: expect.any(String) });
	expect((await lastCommand(page, "updateSpace"))?.color).not.toBe("#5865f2");
});
