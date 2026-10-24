import { expect, test, type Locator, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

async function openProfiles(page: Page, spaceName: string): Promise<void> {
	const world = initialWorld();
	world.spaces[0].name = spaceName;
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receiveBatch([
		{ event: "profileCreated", id: "profile-1", name: "Personal", isDefault: true, color: "#f1a7a5" },
		{ event: "profileCreated", id: "profile-2", name: "Work", isDefault: false, color: "#b39df4" },
		{ event: "openSettings" },
	]));
	await page.locator(".section-nav-button").filter({ hasText: "Tabs and spaces" }).click();
}

test("Rename opens the name ready to type, and Escape leaves it as it was", async ({ page }) => {
	await openProfiles(page, "Work");
	const card = page.locator(".profile-card").nth(1);

	await card.locator(".more-btn").click();
	await card.getByRole("menuitem", { name: "Rename" }).click();
	await page.keyboard.type("Clients");
	await page.keyboard.press("Enter");
	await expect.poll(async () => (await sentCommands(page)).findLast((c) => c.action === "updateProfile")?.payload)
		.toEqual({ id: "profile-2", name: "Clients" });
	await expect(card.locator("input")).toHaveCount(0);

	await card.locator(".more-btn").click();
	await card.getByRole("menuitem", { name: "Rename" }).click();
	await page.keyboard.type("Nope");
	await page.keyboard.press("Escape");
	await expect(card.locator("input")).toHaveCount(0);
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
	expect((await sentCommands(page)).filter((c) => c.action === "updateProfile")).toHaveLength(1);
});

async function openColors(page: Page): Promise<Locator> {
	await openProfiles(page, "Work");
	const card = page.locator(".profile-card").nth(1);
	await card.locator(".more-btn").click();
	await card.getByRole("menuitem", { name: "Change color" }).click();
	await expect(card.locator(".mini-swatch:focus")).toHaveCount(1);
	return card;
}

async function expectColorsClosed(page: Page, card: Locator): Promise<void> {
	await expect(card.locator(".mini-swatch")).toHaveCount(0);
	await expect(card.locator(".more-btn")).toBeFocused();
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
}

const colorUpdates = async (page: Page) =>
	(await sentCommands(page)).filter((c) => c.action === "updateProfile").map((c) => c.payload);

test("Change color opens on the swatches, and Escape closes them without closing Settings", async ({ page }) => {
	const card = await openColors(page);
	await page.keyboard.press("Escape");

	await expectColorsClosed(page, card);
	expect(await colorUpdates(page)).toEqual([]);
});

test("picking a color applies it and closes the swatches", async ({ page }) => {
	const card = await openColors(page);
	await card.locator(".mini-swatch:not(.selected)").first().click();

	await expectColorsClosed(page, card);
	const updates = await colorUpdates(page);
	expect(updates).toEqual([{ id: "profile-2", color: expect.any(String) }]);
	expect(updates[0].color).not.toBe("#b39df4");
});

test("a click outside the swatches closes them without changing the color", async ({ page }) => {
	const card = await openColors(page);
	await card.locator(".card-name").click();

	await expect(card.locator(".mini-swatch")).toHaveCount(0);
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
	expect(await colorUpdates(page)).toEqual([]);
});

test("choosing Change color again closes the swatches without changing the color", async ({ page }) => {
	const card = await openColors(page);
	await card.locator(".more-btn").click();
	await card.getByRole("menuitem", { name: "Change color" }).click();

	await expectColorsClosed(page, card);
	expect(await colorUpdates(page)).toEqual([]);
});

/** Each card's background and the WCAG contrast of its name and Space chip text on it. */
const cardColors = (page: Page) => page.locator(".profile-card").evaluateAll((cards) => {
	const canvas = document.createElement("canvas").getContext("2d", { willReadFrequently: true })!;
	// Paints the colors over each other (translucent ones blend) and reads the result back.
	const paint = (...colors: string[]) => {
		canvas.clearRect(0, 0, 1, 1);
		for (const color of colors) {
			canvas.fillStyle = color;
			canvas.fillRect(0, 0, 1, 1);
		}
		return [...canvas.getImageData(0, 0, 1, 1).data.slice(0, 3)];
	};
	const luminance = (rgb: number[]) => {
		const [r, g, b] = rgb.map((c) => (c / 255 <= 0.03928 ? c / 255 / 12.92 : ((c / 255 + 0.055) / 1.055) ** 2.4));
		return 0.2126 * r + 0.7152 * g + 0.0722 * b;
	};
	const ratio = (a: number[], b: number[]) => {
		const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
		return (hi + 0.05) / (lo + 0.05);
	};
	const page = getComputedStyle(document.documentElement).getPropertyValue("--bg-primary");
	return cards.map((card) => {
		const background = getComputedStyle(card).backgroundColor;
		const name = card.querySelector(".card-name")!;
		const chip = card.querySelector(".chip")!;
		const surface = paint(background);
		const chipSurface = paint(background, getComputedStyle(chip).backgroundColor);
		return {
			background: surface.join(","),
			page: paint(page).join(","),
			nameContrast: ratio(paint(getComputedStyle(name).color), surface),
			chipContrast: ratio(paint(getComputedStyle(chip).color), chipSurface),
		};
	});
});

for (const colorScheme of ["light", "dark"] as const) {
	test(`a profile card wears a wash of its color with readable text in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
		await openProfiles(page, "Work");
		const cards = page.locator(".profile-card");
		await expect(cards).toHaveCount(2);
		await expect(cards.first().locator(".card-name")).toHaveText("Personal");
		// No initials tile: the card's only text up top is the profile's name.
		await expect(cards.first().locator(".card-top")).toHaveText("Personal");
		await page.waitForTimeout(300);

		const [personal, work] = await cardColors(page);
		expect(personal.background).not.toBe(personal.page);
		expect(work.background).not.toBe(personal.background);
		for (const card of [personal, work]) {
			expect(card.nameContrast).toBeGreaterThanOrEqual(4.5);
			expect(card.chipContrast).toBeGreaterThanOrEqual(4.5);
		}
	});
}

test("a long Space name in a profile card ends in an ellipsis inside the card", async ({ page }) => {
	await openProfiles(page, "A Space with a remarkably long name that never seems to end at all");
	const card = page.locator(".profile-card").first();
	const chip = card.locator(".chip").first();
	await expect(chip).toBeVisible();

	const cardBox = (await card.boundingBox())!;
	const chipBox = (await chip.boundingBox())!;
	expect(chipBox.x + chipBox.width).toBeLessThanOrEqual(cardBox.x + cardBox.width - 14);
	const name = chip.locator(".chip-name");
	await expect(name).toHaveCSS("text-overflow", "ellipsis");
	expect(await name.evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(true);
});
