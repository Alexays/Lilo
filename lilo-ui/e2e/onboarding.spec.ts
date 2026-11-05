import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands, type FakeHostWorld } from "./fakeHost";
import { tab, treeItem } from "../src/stores/testFixtures";

// A first launch: one space with one blank tab.
function firstRunWorld(): FakeHostWorld {
	return {
		spaces: [{ id: "space-home", name: "Home", icon: "H", color: "#5865f2", profileId: "profile-1", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: "space-home",
		activeTabBySpace: { "space-home": "tab-blank" },
		tabsBySpace: { "space-home": [tab("tab-blank", "space-home", { url: "", title: "" })] },
		treeItemsBySpace: { "space-home": [treeItem("tab-blank", "space-home", 0)] },
	};
}

async function receive(page: Page, message: Record<string, unknown>): Promise<void> {
	await page.evaluate((msg) => window.__lilo!.receive(msg), message);
}

async function bootOnboarding(page: Page, step: number, usage = "browse", highRefreshDisplay = true): Promise<void> {
	await bootChrome(page, firstRunWorld());
	await receive(page, { event: "onboardingState", show: true, step, usage, highRefreshDisplay });
}

test("the intro keeps the keyboard: Tab stays on its button and Return only starts the onboarding", async ({ page }) => {
	await bootOnboarding(page, 0);
	const cta = page.locator(".intro .cta");
	await expect(cta).toBeVisible();
	await expect(page.locator(".intro .hint")).toHaveText("Press Return to start, Esc to skip");

	await page.keyboard.press("Tab");
	await page.keyboard.press("Tab");
	await expect(cta).toBeFocused();

	await page.keyboard.press("Enter");
	await expect(page.locator(".onb h2")).toHaveText("How will you use Lilo?");
	await expect(page.locator(".command-bar-input")).toHaveCount(0);
});

test("Escape folds the onboarding into the Resume setup pill", async ({ page }) => {
	await bootOnboarding(page, 2);
	await expect(page.locator(".onb")).toBeVisible();

	await page.keyboard.press("Escape");
	await expect(page.locator(".onb")).toHaveCount(0);
	await page.locator(".pill").click();
	await expect(page.locator(".onb")).toBeVisible();
});

test("Escape on the intro skips it, as its hint says, and leaves the setup to resume", async ({ page }) => {
	await bootOnboarding(page, 0);
	await expect(page.locator(".intro .hint")).toContainText("Esc to skip");

	await page.keyboard.press("Escape");
	await expect(page.locator(".intro")).toHaveCount(0);
	await expect(page.locator(".onb")).toHaveCount(0);
	await expect(page.locator(".pill")).toBeVisible();
});

test.describe("in dark mode", () => {
	test.use({ colorScheme: "dark" });

	test("the usage previews draw the window in the dark sidebar's own color", async ({ page }) => {
		await bootOnboarding(page, 1);
		const frame = await page.locator(".pv").first().evaluate((el) => getComputedStyle(el).backgroundColor);
		const sidebar = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--sidebar-bg").trim());
		expect(frame).toBe(await page.evaluate((color) => {
			const probe = document.createElement("span");
			probe.style.color = color;
			document.body.appendChild(probe);
			const value = getComputedStyle(probe).color;
			probe.remove();
			return value;
		}, sidebar));
	});
});

const extensions = Array.from({ length: 18 }, (_, i) => ({ id: `ext-${i}`, name: `Extension ${i + 1}` }));
const chromeSource = {
	id: "chrome", name: "Chrome", family: "chromium", iconDataURL: "", needsFullDiskAccess: false,
	profiles: [
		{ id: "Profile 1", name: "Personal", kinds: ["bookmarks", "history", "extensions"], extensions },
		{ id: "Profile 2", name: "Travail", kinds: ["bookmarks"], extensions: [] },
	],
};

const importedEverything = [
	{ sourceId: "chrome", profileId: "Profile 1", kind: "bookmarks", imported: 1 },
	{ sourceId: "chrome", profileId: "Profile 1", kind: "tabs", imported: 3 },
	{ sourceId: "chrome", profileId: "Profile 1", kind: "history", imported: 2 },
	{ sourceId: "chrome", profileId: "Profile 1", kind: "cookies", imported: 40 },
	{ sourceId: "chrome", profileId: "Profile 1", kind: "extensions", imported: 1 },
];

test("a browser Lilo may not read is one button that opens Full Disk Access, with nothing else to read", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [{ ...chromeSource, needsFullDiskAccess: true, profiles: [] }] });
	const card = page.locator(".onb");
	const tile = card.getByRole("button", { name: /Chrome.*Allow access/ });
	await expect(tile).toBeVisible();
	// The explanation lives in the panel beside System Settings, not in a note under the tiles.
	await expect(card.locator(".note")).toHaveCount(0);
	await expect(card).not.toContainText("Full Disk Access");
	await tile.click();
	expect((await sentCommands(page)).map((command) => command.action)).toContain("openFullDiskAccessSettings");

	// Once access is granted, the rescan unlocks the tile in place, ready to import.
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
	await expect(card.locator(".src.locked")).toHaveCount(0);
	await expect(card.locator(".src.on")).toContainText("Chrome");
	await expect(card.locator(".ob-foot .ob-btn.primary")).toBeEnabled();
});

test("the progress stays short of the end while an extension installs, and names each step", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
	await page.locator(".onb .ob-foot .ob-btn.primary").click();
	const bar = page.getByRole("progressbar");
	const step = page.locator(".progress .step");
	const at = (kind: string, done = 0, total = 0) =>
		receive(page, { event: "importProgress", sourceId: "chrome", profileId: "Profile 1", kind, done, total });

	await at("history");
	await expect(step).toHaveText("Importing history from Personal");
	await at("extensions", 17, 18);
	await expect(step).toHaveText("Reinstalling extensions 18 of 18");
	const now = Number(await bar.getAttribute("aria-valuenow"));
	expect(now).toBeGreaterThan(50);
	expect(now).toBeLessThan(100);

	await receive(page, { event: "importFinished", summary: [
		{ sourceId: "chrome", profileId: "Profile 1", kind: "bookmarks", imported: 1234 },
		{ sourceId: "chrome", profileId: "Profile 1", kind: "extensions", imported: 18 },
	] });
	await expect(bar).toHaveCount(0);
	await expect(page.locator(".note.done")).toHaveText("Done: 1,234 bookmarks and 18 extensions.");
});

for (const viewport of [{ width: 1280, height: 720 }, { width: 1024, height: 640 }]) {
	test.describe(`at ${viewport.width}x${viewport.height}`, () => {
		test.use({ viewport });

		test("the import options keep the title and buttons in view while the screen's body scrolls", async ({ page }) => {
			await bootOnboarding(page, 2);
			await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
			const screen = page.locator(".onb");
			await screen.getByRole("button", { name: "Change" }).click();
			await screen.getByRole("checkbox", { name: "Travail" }).check();
			await expect(screen.getByRole("checkbox", { name: "Extension 18" })).toBeAttached();
			await screen.getByRole("button", { name: "Choose" }).click();

			await expect(screen.locator("h2")).toBeInViewport({ ratio: 1 });
			await expect(screen.locator(".ob-foot .ob-btn.primary")).toBeInViewport({ ratio: 1 });
			const body = screen.locator(".ob-body");
			await expect.poll(() => body.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true);

			// The keyboard reaches the last password manager, which scrolls into view above the fixed buttons.
			const last = screen.getByRole("button", { name: "Add KeePassXC" });
			// The list slides open first: focus scrolls to where the button ends up.
			await expect.poll(() => screen.locator(".managers").evaluate((el) => el.getAnimations().length)).toBe(0);
			await last.focus();
			await expect(last).toBeInViewport({ ratio: 1 });
			await expect(screen.locator(".ob-foot .ob-btn.primary")).toBeInViewport({ ratio: 1 });
		});
	});
}

test("finishing the onboarding leaves the default-browser invite closed", async ({ page }) => {
	await bootOnboarding(page, 3);
	await receive(page, { event: "defaultBrowserStatusLoaded", isDefault: false, shouldInvite: true });
	await page.locator(".onb .ob-foot .ob-btn.primary").click();
	await page.locator(".toast button").click();

	await expect(page.locator(".toast")).toHaveCount(0);
	await expect(page.locator(".url-drawer")).toHaveCount(0);
});

test("a first run reveals the chrome with the intro already on it", async ({ page }) => {
	// Like native: the chrome boots hidden, and the onboarding state lands with the initial state.
	await page.addInitScript(() => {
		let events: unknown[] = [];
		Object.defineProperty(window, "__liloBootstrapEvents", {
			configurable: true,
			get: () => events,
			set: (value: unknown[]) => {
				events = value.length > 0 ? [...value, { event: "onboardingState", show: true, step: 0, usage: "browse" }] : value;
			},
		});
		// The init script runs before the document has its root element.
		const rootAdded = new MutationObserver(() => {
			const root = document.documentElement;
			if (!root) return;
			rootAdded.disconnect();
			root.dataset.booting = "true";
			const reveal = new MutationObserver(() => {
				if (root.dataset.booting) return;
				reveal.disconnect();
				(window as unknown as { revealedWithIntro: boolean }).revealedWithIntro = document.querySelector(".intro") !== null;
			});
			reveal.observe(root, { attributeFilter: ["data-booting"] });
		});
		rootAdded.observe(document, { childList: true });
	});
	await bootChrome(page, firstRunWorld());

	await expect.poll(() => page.evaluate(() => (window as unknown as { revealedWithIntro?: boolean }).revealedWithIntro)).toBe(true);
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("the imported counts group their digits", async ({ page }) => {
		await bootOnboarding(page, 2);
		await receive(page, {
			event: "importSourcesLoaded",
			sources: [{ id: "chrome", name: "Chrome", family: "chromium", iconDataURL: "", needsFullDiskAccess: false, profiles: [{ id: "Default", name: "Moi", kinds: ["history"], extensions: [] }] }],
		});
		await page.locator(".onb .ob-foot .ob-btn.primary").click();
		await receive(page, { event: "importFinished", summary: [{ sourceId: "chrome", profileId: "Default", kind: "history", imported: 12345 }] });

		const spaced = (text: string | null) => (text ?? "").replace(/\s/g, " ");
		expect(spaced(await page.locator(".note.done").textContent())).toContain("12 345 pages d'historique");
		await page.locator(".onb .ob-foot .ob-btn.primary").click();
		await receive(page, { event: "onboardingState", show: true, step: 3, usage: "browse" });
		await page.locator(".onb .ob-foot .ob-btn.primary").click();
		expect(spaced(await page.locator(".toast span").textContent())).toContain("12 345 pages");
	});

	test("the arrival names what came over, each count in its own plural", async ({ page }) => {
		await bootOnboarding(page, 2);
		await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
		await page.locator(".onb .ob-foot .ob-btn.primary").click();
		await receive(page, { event: "importFinished", summary: importedEverything });
		await receive(page, { event: "onboardingState", show: true, step: 3, usage: "browse" });
		await page.locator(".onb .ob-foot .ob-btn.primary").click();

		const text = "Bienvenue dans Lilo. Vos affaires sont là : 1 favori, 3 onglets ouverts, 2 pages d'historique et 1 extension.";
		await expect(page.locator(".toast span")).toHaveText(text);
		await expect(page.locator(".live-announcer")).toHaveText(text);
	});

	test("the intro names the Return key as a French Mac does", async ({ page }) => {
		await bootOnboarding(page, 0);
		await expect(page.locator(".intro .hint")).toHaveText("Appuyez sur Retour pour commencer, Échap pour passer");
	});

	test("the blank tab reads Nouvel onglet", async ({ page }) => {
		await bootChrome(page, firstRunWorld());
		await expect(page.locator('[data-tab-id="tab-blank"] .tab-title')).toHaveText("Nouvel onglet");
	});
});

test.describe("at the window's minimum size", () => {
	test.use({ viewport: { width: 600, height: 400 } });

	test("an essentials row keeps its button on one line and its label readable", async ({ page }) => {
		await bootOnboarding(page, 3);
		await receive(page, { event: "defaultBrowserStatusLoaded", isDefault: false, shouldInvite: false });
		const row = page.locator(".ob-row").filter({ hasText: "Open links in Lilo" });
		const button = row.locator(".ob-btn");
		await expect(button).toBeVisible();

		expect(await button.evaluate((el) => el.scrollHeight <= parseFloat(getComputedStyle(el).fontSize) * 2 + 16)).toBe(true);
		expect((await row.locator(".ob-text").boundingBox())!.width).toBeGreaterThanOrEqual(120);
	});

	test("the essentials keep Continue in view while their rows scroll", async ({ page }) => {
		await bootOnboarding(page, 6);
		await expect(page.locator(".ob-foot .ob-btn.primary")).toBeInViewport({ ratio: 1 });
	});

	test("the intro fits the window down to its keyboard hint", async ({ page }) => {
		await bootOnboarding(page, 0);
		await expect(page.locator(".intro .mark")).toBeInViewport({ ratio: 1 });
		await expect(page.locator(".intro .hint")).toBeInViewport({ ratio: 1 });
	});

	test("the buttons stay at the foot of the window, under a body that scrolls", async ({ page }) => {
		await bootOnboarding(page, 2);
		const screen = page.locator(".onb");
		await expect(screen.getByRole("heading", { name: "Your passwords" })).toBeAttached();
		await expect(screen.locator(".ob-foot .ob-btn").last()).toBeInViewport({ ratio: 1 });
		await expect(screen.locator(".ob-foot .ob-btn").first()).toBeInViewport({ ratio: 1 });
	});

	test("the arrival toast takes the width it has before wrapping", async ({ page }) => {
		await bootOnboarding(page, 4, "develop");
		await receive(page, { event: "settingsLoaded", settings: { agentControlEnabled: "true" } });
		await page.locator(".onb .ob-foot .ob-btn.primary").click();

		const text = page.locator(".toast span");
		const lineHeight = await text.evaluate((el) => parseFloat(getComputedStyle(el).fontSize) * 1.3);
		expect((await text.boundingBox())!.height).toBeLessThanOrEqual(2 * lineHeight);
	});

	test("the arrival toast stays inside the window", async ({ page }) => {
		await bootOnboarding(page, 4, "develop");
		await page.locator(".onb .ob-foot .ob-btn.primary").click();
		const toast = page.locator(".toast");
		await expect(toast.getByRole("button")).toBeInViewport({ ratio: 1 });
		const box = (await toast.boundingBox())!;
		expect(box.x + box.width).toBeLessThanOrEqual(600);
	});
});

const lockedSafari = { id: "safari", name: "Safari", family: "safari", iconDataURL: "", needsFullDiskAccess: true, profiles: [] };

test("a double click on a screen's button moves on one screen, not two", async ({ page }) => {
	await bootOnboarding(page, 3, "agents");
	const screen = page.locator(".onb");
	await expect(screen.getByRole("heading", { name: "Your Lilo" })).toBeVisible();
	const box = (await screen.locator(".ob-foot .ob-btn.primary").boundingBox())!;

	await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2, { clickCount: 2 });
	await expect(screen.getByRole("heading", { name: "Your agents" })).toBeVisible();
	const steps = (await sentCommands(page)).filter((command) => command.action === "setOnboardingStep");
	expect(steps.map((command) => command.payload.step)).toEqual([4]);
});

test("Return runs the screen's main button from a choice it just made", async ({ page }) => {
	await bootOnboarding(page, 1);
	const screen = page.locator(".onb");
	await screen.getByRole("radio", { name: /For developing/ }).click();
	await page.keyboard.press("Enter");
	await expect(screen.getByRole("heading", { name: "Bring your favorites" })).toBeVisible();
});

test("the import step goes back to the usage choice", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
	const card = page.locator(".onb");
	await card.getByRole("button", { name: "Back" }).click();
	await expect(card.getByRole("heading", { name: "How will you use Lilo?" })).toBeVisible();
});

test("each screen hands the keyboard to its main button, never to an action it would trigger by surprise", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
	const screen = page.locator(".onb");
	await screen.getByRole("button", { name: "Skip" }).click();
	await expect(screen.getByRole("heading", { name: "Your Lilo" })).toBeVisible();
	await expect(screen.getByRole("button", { name: "Let's Go" })).toBeFocused();
});

test("the arrow keys move the choice in the usage and theme pickers, which take one Tab stop each", async ({ page }) => {
	await bootOnboarding(page, 1);
	const card = page.locator(".onb");
	const browse = card.getByRole("radio", { name: /For browsing/ });
	const agents = card.getByRole("radio", { name: /With my agents/ });
	await expect(agents).toHaveAttribute("tabindex", "-1");
	await browse.focus();
	await page.keyboard.press("ArrowRight");
	await expect(agents).toBeFocused();
	await expect(agents).toHaveAttribute("aria-checked", "true");
	await expect(browse).toHaveAttribute("tabindex", "-1");

	await receive(page, { event: "onboardingState", show: true, step: 3, usage: "browse" });
	await card.getByRole("radio", { name: "Auto" }).focus();
	await page.keyboard.press("ArrowLeft");
	await expect(card.getByRole("radio", { name: "Dark" })).toBeFocused();
	await expect(card.getByRole("radio", { name: "Dark" })).toHaveAttribute("aria-checked", "true");
});

test("the agents choice turns agents on without the terminal, and asks to connect them", async ({ page }) => {
	await bootOnboarding(page, 1);
	const card = page.locator(".onb");
	await card.getByRole("radio", { name: /With my agents/ }).click();
	await card.getByRole("button", { name: "Continue" }).click();

	const settings = Object.fromEntries((await sentCommands(page)).filter((c) => c.action === "setSetting").map((c) => [c.payload.key, c.payload.value]));
	expect(settings).toMatchObject({ onboardingUsage: "agents", agentControlEnabled: "true", terminalEnabled: "false" });
	await receive(page, { event: "onboardingState", show: true, step: 4, usage: "agents" });
	await expect(card.locator("h2")).toHaveText(/agent/i);
});

test("the agents screen copies Lilo's configuration for any other agent", async ({ page }) => {
	await bootOnboarding(page, 1);
	const card = page.locator(".onb");
	await card.getByRole("radio", { name: /With my agents/ }).click();
	await card.getByRole("button", { name: "Continue" }).click();
	await receive(page, { event: "settingsLoaded", settings: { agentControlEnabled: "true" } });
	await receive(page, { event: "onboardingState", show: true, step: 4, usage: "agents" });

	await card.getByRole("button", { name: "Copy configuration" }).click();

	expect((await sentCommands(page)).filter((c) => c.action === "connectAgentClient").map((c) => c.payload)).toContainEqual({ client: "other" });
	await expect(card).toContainText("Copied");
});

test("a browser without its own icon is read by its name alone", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
	await expect(page.locator(".onb").getByRole("button", { name: "Chrome Personal", exact: true })).toBeVisible();
});

test("a browser waiting for Full Disk Access stops inviting to allow it once the import runs", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource, lockedSafari] });
	const card = page.locator(".onb");
	await card.getByRole("button", { name: "Import", exact: true }).click();
	await expect(card.locator(".src.locked")).toBeDisabled();
	await receive(page, { event: "importFinished", summary: [{ sourceId: "chrome", profileId: "Profile 1", kind: "bookmarks", imported: 3 }] });
	await expect(card.locator(".src.locked")).toBeDisabled();
});

test("a finished import hands the keyboard to Continue", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
	const card = page.locator(".onb");
	await card.getByRole("button", { name: "Import", exact: true }).click();
	await receive(page, { event: "importFinished", summary: [{ sourceId: "chrome", profileId: "Profile 1", kind: "bookmarks", imported: 3 }] });
	await expect(card.getByRole("button", { name: "Continue" })).toBeFocused();
});

test("the arrival sums up the import, sign-ins aside, and speaks the same words", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
	await page.locator(".onb .ob-foot .ob-btn.primary").click();
	await receive(page, { event: "importFinished", summary: [
		...importedEverything,
		{ sourceId: "chrome", profileId: "Profile 2", kind: "bookmarks", imported: 1233 },
		{ sourceId: "chrome", profileId: "Profile 2", kind: "extensions", imported: 0, error: "store" },
	] });
	await receive(page, { event: "onboardingState", show: true, step: 3, usage: "browse" });
	await page.locator(".onb .ob-foot .ob-btn.primary").click();

	const text = "Welcome to Lilo. Your things are here: 1,234 bookmarks, 3 open tabs, 2 pages of history, and 1 extension.";
	await expect(page.locator(".toast span")).toHaveText(text);
	await expect(page.locator(".live-announcer")).toHaveText(text);
});

test("the password managers read as two grouped lists: a manager per row, each description on one line", async ({ page }) => {
	await bootOnboarding(page, 2);
	await page.getByRole("button", { name: "Choose" }).click();
	const groups = page.locator(".managers .ob-group");
	await expect(groups).toHaveCount(2);
	await expect(groups.locator(".ob-row")).toHaveCount(7);
	for (const group of await groups.all()) {
		const boxes = await group.locator(".ob-row").evaluateAll((rows) => rows.map((row) => {
			const box = row.getBoundingClientRect();
			const small = row.querySelector("small")!;
			return { x: box.x, width: box.width, height: box.height, oneLine: small.getBoundingClientRect().height < parseFloat(getComputedStyle(small).fontSize) * 2 };
		}));
		for (const box of boxes) {
			expect(box.x).toBeCloseTo(boxes[0].x, 1);
			expect(box.width).toBeCloseTo(boxes[0].width, 1);
			expect(box.height).toBeCloseTo(boxes[0].height, 1);
			expect(box.oneLine).toBe(true);
		}
	}
});

test("each password manager shows its own icon, and its initial when the icon fails to load", async ({ page }) => {
	await page.route("**/password-managers/nngceckbapebfimnlniiiahkandclblb.png", (route) => route.abort());
	await bootOnboarding(page, 2);
	await page.getByRole("button", { name: "Choose" }).click();
	const rows = page.locator(".managers .ob-row");
	await expect(rows).toHaveCount(7);
	const bitwarden = rows.filter({ hasText: "Bitwarden" });
	await expect(bitwarden.locator(".glyph")).toHaveText("B");
	await expect(bitwarden.locator("img")).toHaveCount(0);

	const others = rows.filter({ hasNotText: "Bitwarden" });
	await expect(others.locator(".glyph")).toHaveCount(0);
	await expect.poll(() => others.locator("img.logo").evaluateAll((images) => images.map((image) => (image as HTMLImageElement).naturalWidth)))
		.toEqual(Array(6).fill(60));
});

test("Your Lilo turns the full refresh rate off and on", async ({ page }) => {
	await bootOnboarding(page, 3);
	const row = page.locator(".ob-row").filter({ hasText: "Smoother scrolling" });
	await expect(row.getByRole("checkbox")).toBeChecked();
	await row.locator(".ui-toggle").click();
	await expect(row.getByRole("checkbox")).not.toBeChecked();
	expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "fullRefreshRate" && command.payload.value === "false")).toBe(true);
});

test("Your Lilo leaves out the refresh rate without a display above 60 Hz", async ({ page }) => {
	await bootOnboarding(page, 3, "browse", false);
	await expect(page.locator(".ob-row").filter({ hasText: "Open links in Lilo" })).toBeVisible();
	await expect(page.locator(".ob-row").filter({ hasText: "Smoother scrolling" })).toHaveCount(0);
});

test("the essentials show one primary action: Use Lilo stays secondary to the screen's own button", async ({ page }) => {
	await bootOnboarding(page, 3, "agents");
	await receive(page, { event: "defaultBrowserStatusLoaded", isDefault: false, shouldInvite: false });
	const card = page.locator(".onb");
	await expect(card.getByRole("button", { name: "Use Lilo" })).toBeVisible();
	await expect(card.locator(".ob-btn.primary")).toHaveCount(1);
	await expect(card.locator(".ob-btn.primary")).toHaveText("Continue");
});

test("the arrival is spoken, since the focus never reaches it", async ({ page }) => {
	await bootOnboarding(page, 3);
	await page.locator(".onb .ob-foot .ob-btn.primary").click();
	await expect(page.locator(".live-announcer")).toHaveText("Welcome to Lilo.");
});

test("the intro's petals become the icon of the Home space a first run starts with", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	const world = firstRunWorld();
	await bootChrome(page, { ...world, spaces: [{ ...world.spaces[0], icon: "🏠" }] });
	await receive(page, { event: "onboardingState", show: true, step: 0, usage: "browse" });
	await page.locator(".intro .cta").click();
	await expect(page.locator(".onb")).toBeVisible();
	expect((await sentCommands(page)).find((command) => command.action === "updateSpace")?.payload).toEqual({ id: "space-home", icon: "🪻" });
});

test("the intro is a modal dialog, so VoiceOver stays out of the chrome under it", async ({ page }) => {
	await bootOnboarding(page, 0);
	const dialog = page.getByRole("dialog", { name: "Welcome home." });
	await expect(dialog).toHaveAttribute("aria-modal", "true");
	await expect(dialog.getByRole("button", { name: "Get started" })).toBeFocused();
});

test("each agent's connect button names it", async ({ page }) => {
	await bootOnboarding(page, 4, "develop");
	await receive(page, { event: "settingsLoaded", settings: { agentControlEnabled: "true" } });
	await receive(page, { event: "agentClientsLoaded", clients: [{ id: "codex", configured: false, icon: "data:image/png;base64,AA==" }], allowed: [] });
	await expect(page.locator(".onb").getByRole("button", { name: "Connect Codex" })).toBeVisible();
});

test.describe("in French at the window's minimum size", () => {
	test.use({ locale: "fr-FR", viewport: { width: 600, height: 400 } });

	test("the import keeps what to import in reach beside a locked browser", async ({ page }) => {
		await bootOnboarding(page, 2);
		await receive(page, { event: "importSourcesLoaded", sources: [chromeSource, lockedSafari] });
		const screen = page.locator(".onb");
		await screen.getByRole("button", { name: "Modifier" }).click();
		const chip = screen.getByRole("button", { name: "Historique" });
		await chip.scrollIntoViewIfNeeded();
		await expect(chip).toBeInViewport({ ratio: 1 });
		await expect(screen.getByRole("button", { name: /Safari.*Autoriser l'accès/ })).toBeVisible();
	});
});

test("Your Lilo moves the real window and draws the chosen edge in its preview", async ({ page }) => {
	await bootOnboarding(page, 3);
	const screen = page.locator(".onb");
	await expect(screen.getByRole("heading", { name: "Your Lilo" })).toBeVisible();

	await screen.getByRole("radio", { name: "Top" }).click();

	const sets = (await sentCommands(page)).filter((c) => c.action === "setSetting");
	expect(sets.at(-1)?.payload).toEqual({ key: "tabPosition", value: "top" });
	await receive(page, { event: "tabLayoutChanged", position: "top", address: "tabs" });
	await expect(screen.locator(".win")).toHaveClass(/tabs-top/);
});

test("Your Lilo lays its look out as settings rows, the address among them moving the real window", async ({ page }) => {
	await bootOnboarding(page, 3);
	const screen = page.locator(".onb");
	await expect(screen.getByRole("heading", { name: "Look" })).toBeVisible();
	for (const name of ["Tabs", "Address", "Theme", "Material"]) {
		await expect(screen.getByRole("radiogroup", { name })).toBeVisible();
	}
	await expect(screen.getByRole("radiogroup", { name: "Address" }).getByRole("radio")).toHaveText(["With the tabs", "Above the page", "Hidden"]);
	await expect(screen.locator(".win .tabs .url")).toBeVisible();

	await screen.getByRole("radio", { name: "Above the page" }).click();
	const sets = (await sentCommands(page)).filter((c) => c.action === "setSetting");
	expect(sets.at(-1)?.payload).toEqual({ key: "addressPlacement", value: "page" });
	await receive(page, { event: "tabLayoutChanged", position: "left", address: "page" });
	await expect(screen.getByRole("radio", { name: "Above the page" })).toHaveAttribute("aria-checked", "true");
	await expect(screen.locator(".win .page .addr")).toBeVisible();
	await expect(screen.locator(".win .tabs .url")).toHaveCount(0);
});

test("the preview paints the window in the sidebar's own derived color, with the selected row as its selected layer", async ({ page }) => {
	await bootOnboarding(page, 3);
	const win = page.locator(".onb .win");
	const colors = await win.evaluate((el) => {
		const root = getComputedStyle(document.documentElement);
		const probe = (color: string) => {
			const span = document.createElement("span");
			span.style.color = color;
			document.body.appendChild(span);
			const value = getComputedStyle(span).color;
			span.remove();
			return value;
		};
		return {
			window: getComputedStyle(el).backgroundColor,
			sidebar: probe(root.getPropertyValue("--sidebar-bg").trim()),
			row: getComputedStyle(el.querySelector(".row.sel")!).backgroundColor,
			selected: probe(root.getPropertyValue("--sidebar-sel").trim()),
		};
	});
	expect(colors.window).toBe(colors.sidebar);
	expect(colors.row).toBe(colors.selected);
});

test("after the onboarding, a tip shows once, the first time the person meets what it is about", async ({ page }) => {
	await bootOnboarding(page, 3);
	await page.locator(".onb .ob-foot .ob-btn.primary").click();
	await page.locator(".toast button").click();
	const agentsSpace = { event: "agentActivity", clients: [], agentsSpaceIds: ["space-agents"], agentsProfileId: "", hiddenAgentsSpaceIds: [], isolatedSpaceIds: [], moods: {} };
	await receive(page, agentsSpace);

	await expect(page.locator(".tip")).toHaveText("Your agents open their tabs in the Agents Space.");
	const seen = (await sentCommands(page)).filter((c) => c.action === "setSetting" && c.payload.key === "seenTips").map((c) => c.payload.value);
	expect(seen.at(-1)).toBe("agents");
});

test("what the import takes reads as one sentence, its options open on Change", async ({ page }) => {
	await bootOnboarding(page, 2);
	await receive(page, { event: "importSourcesLoaded", sources: [chromeSource] });
	const screen = page.locator(".onb");
	await expect(screen.locator(".summary")).toContainText("Imports bookmarks, open tabs, history, your sign-ins, and 18 extensions.");
	await expect(screen.locator(".chip")).toHaveCount(0);

	await screen.getByRole("button", { name: "Change" }).click();
	await expect(screen.locator(".chip")).toHaveCount(5);
});
