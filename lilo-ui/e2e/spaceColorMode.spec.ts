import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands, type FakeHostWorld } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

const sidebarBackground = (page: Page) =>
	page.evaluate(() => document.documentElement.style.getPropertyValue("--sidebar-bg").trim());

const lastCommand = async (page: Page, action: string) =>
	(await sentCommands(page)).filter((command) => command.action === action).at(-1)?.payload;

const colorModes = (page: Page) => page.getByRole("radiogroup", { name: /^(color|color of lilo)$/i });

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

test("each color mode previews on the whole chrome, the base color stays editable, and Save sends the mode", async ({ page }) => {
	await bootInTheEvening(page, worldOnAColorfulSite());
	const fixed = await sidebarBackground(page);
	await page.evaluate((id) => window.__lilo!.receive({ event: "openSpaceEditor", id }), SPACE_1);
	await expect(page.locator(".editor-panel")).toBeVisible();

	const modes = colorModes(page);
	await expect(modes.getByRole("radio")).toHaveCount(4);
	await expect(modes.getByRole("radio", { name: "Fixed" })).toHaveAttribute("aria-checked", "true");

	await modes.getByRole("radio", { name: "Time of day" }).click();
	await expect(page.getByText("This color, warmer in the evening and darker at night.")).toBeVisible();
	await expect.poll(() => sidebarBackground(page)).not.toBe(fixed);
	// The base color is still the user's to pick under a moving mode.
	const evening = await sidebarBackground(page);
	await page.locator(".color-swatch").first().click();
	await expect.poll(() => sidebarBackground(page)).not.toBe(evening);

	await modes.getByRole("radio", { name: "Page" }).click();
	const tinted = await sidebarBackground(page);
	await page.locator(".color-swatch").first().click();
	expect(tinted).not.toBe(evening);

	await modes.getByRole("radio", { name: "Wallpaper" }).click();
	await expect.poll(() => lastCommand(page, "setWallpaperColorWatch")).toEqual({ enabled: true });
	await page.evaluate(() => window.__lilo!.receive({ event: "wallpaperColorChanged", color: "#2f9e8f" }));
	await expect.poll(() => sidebarBackground(page)).not.toBe(tinted);

	await page.keyboard.press("Meta+Enter");
	await expect(page.locator(".editor-panel")).toHaveCount(0);
	expect(await lastCommand(page, "updateSpace")).toMatchObject({ id: SPACE_1, colorMode: "wallpaper" });
	// Back on the saved fixed Space (the host has not echoed the change): the wallpaper is no longer watched.
	await expect.poll(() => lastCommand(page, "setWallpaperColorWatch")).toEqual({ enabled: false });
});

test("the arrow keys move between the color modes", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate((id) => window.__lilo!.receive({ event: "openSpaceEditor", id }), SPACE_1);
	const modes = colorModes(page);
	await modes.getByRole("radio", { name: "Fixed" }).focus();
	await page.keyboard.press("ArrowRight");
	await expect(modes.getByRole("radio", { name: "Time of day" })).toBeFocused();
	await expect(modes.getByRole("radio", { name: "Time of day" })).toHaveAttribute("aria-checked", "true");
	await page.keyboard.press("ArrowLeft");
	await page.keyboard.press("ArrowLeft");
	await expect(modes.getByRole("radio", { name: "Wallpaper" })).toHaveAttribute("aria-checked", "true");
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

test("the onboarding's appearance step sets where the current Space's color comes from", async ({ page }) => {
	const world: FakeHostWorld = {
		spaces: [{ id: "space-home", name: "Home", icon: "H", color: "#5865f2", profileId: "profile-1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: "space-home",
		activeTabBySpace: { "space-home": "tab-blank" },
		tabsBySpace: { "space-home": [tab("tab-blank", "space-home", { url: "", title: "" })] },
		treeItemsBySpace: { "space-home": [treeItem("tab-blank", "space-home", 0)] },
	};
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "onboardingState", show: true, step: 4, usage: "browse" }));
	const modes = colorModes(page);
	await expect(modes).toBeVisible();
	await expect(modes.getByRole("radio", { name: "Fixed" })).toHaveAttribute("aria-checked", "true");

	await modes.getByRole("radio", { name: "Time of day" }).click();
	await expect.poll(() => lastCommand(page, "updateSpace")).toEqual({ id: "space-home", colorMode: "time" });
	await page.evaluate(() => window.__lilo!.receive({ event: "spaceUpdated", ...{ id: "space-home", name: "Home", icon: "H", color: "#5865f2", profileId: "profile-1", isPrivate: false, sortOrder: 0, colorMode: "time" } }));
	await expect(modes.getByRole("radio", { name: "Time of day" })).toHaveAttribute("aria-checked", "true");
	await expect(page.getByText("This color, warmer in the evening and darker at night.")).toBeVisible();
});
