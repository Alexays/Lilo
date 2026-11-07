import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands, type FakeHostWorld } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

const sidebarBackground = (page: Page) =>
	page.evaluate(() => document.documentElement.style.getPropertyValue("--sidebar-bg").trim());

const lastCommand = async (page: Page, action: string) =>
	(await sentCommands(page)).filter((command) => command.action === action).at(-1)?.payload;

const source = (page: Page, name: string) => page.getByRole("radiogroup", { name: /^Color/ }).getByRole("radio", { name, exact: true });
const hue = (page: Page) => page.getByRole("slider", { name: "Hue" });

async function openAppearance(page: Page): Promise<void> {
	await page.evaluate((id) => window.__lilo!.receive({ event: "openSpaceEditor", id }), SPACE_1);
	await expect(page.locator(".editor-panel")).toBeVisible();
}

const dayToggle = (page: Page) => page.locator(".ui-toggle", { has: page.getByRole("checkbox", { name: "Change with the time of day" }) });

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

test("each color source and material previews on the whole chrome, and is sent as it is picked", async ({ page }) => {
	await bootInTheEvening(page, worldOnAColorfulSite());
	const fixed = await sidebarBackground(page);
	await openAppearance(page);

	await expect(source(page, "Pick")).toHaveAttribute("aria-checked", "true");

	await dayToggle(page).click();
	await expect.poll(() => sidebarBackground(page)).not.toBe(fixed);
	// The base color is still the user's to pick while it follows the day.
	const evening = await sidebarBackground(page);
	await hue(page).fill("120");
	await expect.poll(() => sidebarBackground(page)).not.toBe(evening);

	// The active tab's site brings the color: the sliders give way to what it does, and the day has nothing to change.
	await source(page, "Site").click();
	await expect(page.locator(".editor-panel .box .note")).toHaveText("Lilo takes the color of the site in the active tab.");
	await expect(hue(page)).toHaveCount(0);
	await expect(dayToggle(page)).toHaveCount(0);
	await expect.poll(() => sidebarBackground(page)).not.toBe(evening);
	const tinted = await sidebarBackground(page);

	await source(page, "Wallpaper").click();
	await expect.poll(() => lastCommand(page, "setWallpaperColorWatch")).toEqual({ enabled: true });
	await page.evaluate(() => window.__lilo!.receive({ event: "wallpaperColorChanged", color: "#2f9e8f", thumbnail: "data:image/jpeg;base64,AAAA" }));
	await expect.poll(() => sidebarBackground(page)).not.toBe(tinted);
	// The Glass swatch shows the wallpaper itself through the Space color.
	expect(await page.locator(".swatch-material.glass").evaluate((node) => getComputedStyle(node).backgroundImage)).toContain("data:image/jpeg");

	// Pick takes back from Lilo's pick.
	await source(page, "Pick").click();
	await expect(hue(page)).toBeVisible();
	await source(page, "Wallpaper").click();
	await page.getByRole("radiogroup", { name: "Material" }).getByRole("radio", { name: "Grain" }).click();
	await expect.poll(() => page.evaluate(() => document.documentElement.dataset.material)).toBe("grain");

	await page.keyboard.press("Escape");
	await expect(page.locator(".editor-panel")).toHaveCount(0);
	expect(await lastCommand(page, "updateSpace")).toMatchObject({ id: SPACE_1, colorMode: "wallpaper", material: "grain" });
	// Back on the fixed Space (the host has not echoed the change): the wallpaper is no longer watched.
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

test("the onboarding's Your Lilo screen sets the current Space's color and material", async ({ page }) => {
	const world: FakeHostWorld = {
		spaces: [{ id: "space-home", name: "Home", icon: "H", color: "#5865f2", profileId: "profile-1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: "space-home",
		activeTabBySpace: { "space-home": "tab-blank" },
		tabsBySpace: { "space-home": [tab("tab-blank", "space-home", { url: "", title: "" })] },
		treeItemsBySpace: { "space-home": [treeItem("tab-blank", "space-home", 0)] },
	};
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({ event: "onboardingState", show: true, step: 3, usage: "browse" }));
	const followDay = page.getByRole("checkbox", { name: "Change with the time of day" });
	await expect(followDay).not.toBeChecked();
	await page.locator(".ui-toggle", { has: followDay }).click();
	await expect.poll(() => lastCommand(page, "updateSpace")).toEqual({ id: "space-home", colorMode: "time" });
	await page.evaluate(() => window.__lilo!.receive({ event: "spaceUpdated", ...{ id: "space-home", name: "Home", icon: "H", color: "#5865f2", profileId: "profile-1", isPrivate: false, sortOrder: 0, colorMode: "time" } }));
	await expect(followDay).toBeChecked();

	await page.getByRole("radiogroup", { name: "Material" }).getByRole("radio", { name: "Glass" }).click();
	await expect.poll(() => lastCommand(page, "updateSpace")).toEqual({ id: "space-home", material: "glass" });

	// The sliders sit under the Color row, the color named under its label.
	await expect(source(page, "Pick")).toHaveAttribute("aria-checked", "true");
	await expect(page.locator(".ob-text small").first()).toHaveText("Custom color");

	// The color is the user's here too, sent at once.
	await hue(page).fill("30");
	await expect.poll(() => lastCommand(page, "updateSpace")).toMatchObject({ id: "space-home", color: expect.any(String) });
	expect((await lastCommand(page, "updateSpace"))?.color).not.toBe("#5865f2");
});
