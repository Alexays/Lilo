import { expect, test, type Page } from "@playwright/test";
import { bootChrome, type FakeHostWorld } from "./fakeHost";
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

async function bootOnboarding(page: Page, step: number, usage = "browse"): Promise<void> {
	await bootChrome(page, firstRunWorld());
	await receive(page, { event: "onboardingState", show: true, step, usage });
}

test("the intro keeps the keyboard: Tab stays on its button and Enter only starts the onboarding", async ({ page }) => {
	await bootOnboarding(page, 0);
	const cta = page.locator(".intro .cta");
	await expect(cta).toBeVisible();

	await page.keyboard.press("Tab");
	await page.keyboard.press("Tab");
	await expect(cta).toBeFocused();

	await page.keyboard.press("Enter");
	await expect(page.locator("section.card")).toBeVisible();
	await expect(page.locator(".command-bar-input")).toHaveCount(0);
});

test("Escape folds the card into the Resume setup pill", async ({ page }) => {
	await bootOnboarding(page, 3);
	await expect(page.locator("section.card")).toBeVisible();

	await page.keyboard.press("Escape");
	await expect(page.locator("section.card")).toHaveCount(0);
	await page.locator(".pill").click();
	await expect(page.locator("section.card")).toBeVisible();
});

test("Escape on the intro skips it, as its hint says, and leaves the setup to resume", async ({ page }) => {
	await bootOnboarding(page, 0);
	await expect(page.locator(".intro .hint")).toContainText("Esc to skip");

	await page.keyboard.press("Escape");
	await expect(page.locator(".intro")).toHaveCount(0);
	await expect(page.locator("section.card")).toHaveCount(0);
	await expect(page.locator(".pill")).toBeVisible();
});

test("the card's tiles and buttons lift alike under the pointer", async ({ page }) => {
	const lift = async (selector: string) => {
		await page.locator(selector).first().hover();
		return expect.poll(() => page.locator(selector).first().evaluate((el) => new DOMMatrix(getComputedStyle(el).transform).m42));
	};
	await bootOnboarding(page, 1);
	await (await lift(".us")).toBe(-1);
	await (await lift(".ob-foot .ob-btn.primary")).toBe(-1);
	await receive(page, { event: "onboardingState", show: true, step: 4, usage: "browse" });
	await (await lift(".th")).toBe(-1);
});

test.describe("in dark mode", () => {
	test.use({ colorScheme: "dark" });

	test("the usage previews draw a dark Lilo", async ({ page }) => {
		await bootOnboarding(page, 1);
		const page_ = await page.locator(".pv-browse u").evaluate((el) => getComputedStyle(el).backgroundColor);
		const background = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--bg-primary").trim());
		expect(page_).toBe(await page.evaluate((color) => {
			const probe = document.createElement("span");
			probe.style.color = color;
			document.body.appendChild(probe);
			const value = getComputedStyle(probe).color;
			probe.remove();
			return value;
		}, background));
	});
});

test("finishing the onboarding leaves the default-browser invite closed", async ({ page }) => {
	await bootOnboarding(page, 6);
	await receive(page, { event: "defaultBrowserStatusLoaded", isDefault: false, shouldInvite: true });
	await page.locator("section.card .ob-foot .ob-btn.primary").click();
	await page.locator(".toast button").click();

	await expect(page.locator(".toast")).toHaveCount(0);
	await expect(page.locator(".url-drawer-content > *")).toHaveCount(0);
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
		await page.locator("section.card .ob-foot .ob-btn.primary").click();
		await receive(page, { event: "importFinished", summary: [{ sourceId: "chrome", profileId: "Default", kind: "history", imported: 12345 }] });

		const spaced = (text: string | null) => (text ?? "").replace(/\s/g, " ");
		expect(spaced(await page.locator(".note.done").textContent())).toContain("12 345 éléments");
		await page.locator("section.card .ob-foot .ob-btn.primary").click();
		await receive(page, { event: "onboardingState", show: true, step: 7, usage: "browse" });
		await page.locator("section.card .ob-foot .ob-btn.primary").click();
		expect(spaced(await page.locator(".toast span").textContent())).toContain("12 345 pages");
	});

	test("the blank tab reads Nouvel onglet", async ({ page }) => {
		await bootChrome(page, firstRunWorld());
		await expect(page.locator('[data-tab-id="tab-blank"] .tab-title')).toHaveText("Nouvel onglet");
	});
});

test.describe("at the window's minimum size", () => {
	test.use({ viewport: { width: 600, height: 400 } });

	test("an essentials row keeps its button on one line and its label readable", async ({ page }) => {
		await bootOnboarding(page, 5);
		await receive(page, { event: "defaultBrowserStatusLoaded", isDefault: false, shouldInvite: false });
		const row = page.locator(".ob-row").filter({ has: page.locator(".ob-btn") });
		const button = row.locator(".ob-btn");
		await expect(button).toBeVisible();

		expect(await button.evaluate((el) => el.scrollHeight <= parseFloat(getComputedStyle(el).fontSize) * 2 + 16)).toBe(true);
		expect((await row.locator(".ob-text").boundingBox())!.width).toBeGreaterThanOrEqual(120);
	});

	test("the intro fits the window down to its keyboard hint", async ({ page }) => {
		await bootOnboarding(page, 0);
		await expect(page.locator(".intro .mark")).toBeInViewport({ ratio: 1 });
		await expect(page.locator(".intro .hint")).toBeInViewport({ ratio: 1 });
	});

	test("the card fits the window and scrolls to its footer", async ({ page }) => {
		await bootOnboarding(page, 3);
		const card = page.locator("section.card");
		await expect(card.getByRole("heading", { name: "Your passwords" })).toBeVisible();
		const box = (await card.boundingBox())!;
		expect(box.y).toBeGreaterThanOrEqual(0);
		expect(box.y + box.height).toBeLessThanOrEqual(400);

		const skip = card.locator(".ob-foot .ob-btn").last();
		await skip.scrollIntoViewIfNeeded();
		await expect(skip).toBeInViewport({ ratio: 1 });
	});

	test("the arrival toast takes the width it has before wrapping", async ({ page }) => {
		await bootOnboarding(page, 7, "develop");
		await receive(page, { event: "settingsLoaded", settings: { agentControlEnabled: "true" } });
		await page.locator("section.card .ob-foot .ob-btn.primary").click();

		const text = page.locator(".toast span");
		const lineHeight = await text.evaluate((el) => parseFloat(getComputedStyle(el).fontSize) * 1.3);
		expect((await text.boundingBox())!.height).toBeLessThanOrEqual(2 * lineHeight);
	});

	test("the arrival toast stays inside the window", async ({ page }) => {
		await bootOnboarding(page, 7, "develop");
		await page.locator("section.card .ob-foot .ob-btn.primary").click();
		const toast = page.locator(".toast");
		await expect(toast.getByRole("button")).toBeInViewport({ ratio: 1 });
		const box = (await toast.boundingBox())!;
		expect(box.x + box.width).toBeLessThanOrEqual(600);
	});
});
