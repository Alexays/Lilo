import { expect, test, type Page } from "@playwright/test";
import { installFakeHost, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";
import type { BridgeLittleState } from "../src/lib/bridge";

const SPACE = { id: "space-home", name: "Home", icon: "🏠", color: "#5865f2" };
const OTHERS = [
	{ id: "space-work", name: "Work", icon: "💼" },
	{ id: "space-play", name: "Play", icon: "🎮" },
];

async function bootLittle(page: Page, state: Partial<BridgeLittleState> = {}): Promise<void> {
	await installFakeHost(page, initialWorld());
	await page.goto("/?little");
	await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "littleReady")).toBe(true);
	await sendState(page, state);
}

async function sendState(page: Page, state: Partial<BridgeLittleState>): Promise<void> {
	const full: BridgeLittleState = { mode: "start", url: "", loading: false, space: SPACE, otherSpaces: OTHERS, leadingInset: 78, ...state };
	await page.evaluate((payload) => window.__lilo!.receive({ event: "littleState", ...payload }), full);
}

test("the start view is the command bar in place, focused, with no tab, Space or action rows", async ({ page }) => {
	await bootLittle(page);

	await expect(page.locator(".command-bar-backdrop.docked")).toBeVisible();
	await expect(page.locator(".command-bar-input")).toBeFocused();
	await expect(page.locator(".little-bar")).toHaveCount(0);
	// Nothing about tabs or actions: the bar has none here.
	await expect(page.locator(".command-bar-input")).toHaveAttribute("placeholder", "Search or enter URL...");
	await expect(page.locator(".command-bar-section-title", { hasText: "Quick actions" })).toHaveCount(0);
	await page.locator(".command-bar-input").fill(":settings");
	await expect(page.locator(".command-bar-section-title", { hasText: "Actions" })).toHaveCount(0);
	// Chips for what a window without tabs can search: everything and history.
	// The chips row in the default layout, the scope menu in the compact one.
	const picker = page.locator(".scope-picker");
	if (await picker.count()) await picker.click();
	await expect(page.locator(".scope-hint .scope-hint-label, .scope-menu .scope-label")).toHaveText(["All", "History"]);
});

test("Escape and the close button close the start view", async ({ page }) => {
	await bootLittle(page);
	const input = page.locator(".command-bar-input");

	await input.press("Escape");
	await expect.poll(async () => (await sentCommands(page)).filter((c) => c.action === "littleClose").length).toBe(1);

	await page.getByRole("button", { name: "Close" }).click();
	await expect.poll(async () => (await sentCommands(page)).filter((c) => c.action === "littleClose").length).toBe(2);
});

test("Escape leaves a typed scope before it closes the window", async ({ page }) => {
	await bootLittle(page);
	const input = page.locator(".command-bar-input");
	await input.fill("/example");

	await input.press("Escape");

	expect((await sentCommands(page)).some((c) => c.action === "littleClose")).toBe(false);
	await input.press("Escape");
	await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "littleClose")).toBe(true);
});

test("Enter on an address navigates the window's page", async ({ page }) => {
	await bootLittle(page);
	const input = page.locator(".command-bar-input");

	await input.fill("example.com/docs");
	await input.press("Enter");

	await expect
		.poll(async () => (await sentCommands(page)).filter((c) => c.action === "navigate").map((c) => c.payload.url))
		.toEqual(["https://example.com/docs"]);
});

test("a page swaps the bar for the strip: address, copy link and Open in the Space", async ({ page }) => {
	await bootLittle(page);
	await sendState(page, { mode: "page", url: "https://www.example.com/read?page=2" });

	await expect(page.locator(".command-bar-backdrop")).toHaveCount(0);
	const strip = page.locator(".little-bar");
	await expect(strip.locator(".host")).toHaveText("example.com");
	await expect(strip).toHaveCSS("padding-left", "78px");

	await page.getByRole("button", { name: "Copy link" }).click();
	await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "littleCopyLink")).toBe(true);

	const open = strip.getByRole("button", { name: /Open in 🏠 Home/ });
	await expect(open).toContainText("⌘O");
	await open.click();
	await expect
		.poll(async () => (await sentCommands(page)).filter((c) => c.action === "littleOpenInSpace").map((c) => c.payload))
		.toEqual([{}]);
});

test("the chevron lists the other Spaces and files the page in the one picked", async ({ page }) => {
	await bootLittle(page, { mode: "page", url: "https://example.com/" });

	await page.getByRole("button", { name: "Open in another Space" }).click();
	const items = page.getByRole("menuitem");
	await expect(items).toHaveText(["Open in 💼 Work", "Open in 🎮 Play"]);
	await items.nth(1).click();

	await expect
		.poll(async () => (await sentCommands(page)).filter((c) => c.action === "littleOpenInSpace").map((c) => c.payload))
		.toEqual([{ spaceId: "space-play" }]);
});

test("Escape closes the page view, but first leaves the bar opened over the page", async ({ page }) => {
	await bootLittle(page, { mode: "page", url: "https://example.com/" });
	await page.locator(".address").click();
	const input = page.locator(".command-bar-input");
	await expect(input).toHaveValue("https://example.com/");
	await expect(page.locator(".command-bar-backdrop.docked")).toHaveCount(0);

	await input.press("Escape");

	await expect(page.locator(".command-bar-backdrop")).toHaveCount(0);
	expect((await sentCommands(page)).some((c) => c.action === "littleClose")).toBe(false);
	await page.keyboard.press("Escape");
	await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "littleClose")).toBe(true);
});

test("the loading line shows while the page loads and holds still under Reduce motion", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootLittle(page, { mode: "page", url: "https://example.com/", loading: true });

	const progress = page.locator(".little-bar .progress");
	await expect(progress).toHaveCSS("opacity", "1");
	await expect(progress).toHaveCSS("animation-name", "none");
	await sendState(page, { mode: "page", url: "https://example.com/", loading: false });
	await expect(progress).toHaveCSS("opacity", "0");
});
