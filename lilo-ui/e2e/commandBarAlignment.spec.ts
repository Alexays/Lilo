import { expect, test, type Locator, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

type Box = { x: number; y: number; width: number; height: number };

const centerY = (box: Box) => box.y + box.height / 2;
const centerX = (box: Box) => box.x + box.width / 2;

async function box(locator: Locator): Promise<Box> {
	return (await locator.boundingBox())!;
}

// The box of an element's text itself, which can sit off-center inside the element's own box.
async function textBox(locator: Locator): Promise<Box> {
	return locator.evaluate((el) => {
		const range = document.createRange();
		range.selectNodeContents(el);
		const { x, y, width, height } = range.getBoundingClientRect();
		return { x, y, width, height };
	});
}

async function openActions(page: Page): Promise<void> {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").fill(":");
	await expect(page.locator(".command-bar-result").first()).toBeVisible();
	// Some actions arrive a moment later and shift the rows: measure once the list holds still.
	let last = "";
	await expect
		.poll(async () => {
			const now = JSON.stringify(await page.locator(".command-bar-result").evaluateAll((rows) => rows.map((row) => row.getBoundingClientRect().y)));
			const settled = now === last;
			last = now;
			return settled;
		}, { intervals: [100] })
		.toBe(true);
}

test("action rows draw a line icon centered in its tile, the tile centered on the title block", async ({ page }) => {
	await openActions(page);

	const rows = await page.locator(".command-bar-result").all();
	expect(rows.length).toBeGreaterThan(3);
	for (const row of rows) {
		const tile = row.locator(".result-icon");
		await expect(tile).toHaveText("");
		const tileBox = await box(tile);
		const iconBox = await box(tile.locator("svg"));
		expect(Math.abs(centerX(iconBox) - centerX(tileBox))).toBeLessThanOrEqual(0.5);
		expect(Math.abs(centerY(iconBox) - centerY(tileBox))).toBeLessThanOrEqual(0.5);
		expect(Math.abs(centerY(tileBox) - centerY(await box(row.locator(".result-main"))))).toBeLessThanOrEqual(0.5);
	}
});

for (const width of [1000, 600]) {
	test(`the search icon, the section header and the row tiles share one left edge at ${width}px`, async ({ page }) => {
		await page.setViewportSize({ width, height: 640 });
		await openActions(page);

		const edge = (await box(page.locator(".command-bar-icon"))).x;
		expect(Math.abs((await textBox(page.locator(".command-bar-section-title").first())).x - edge)).toBeLessThanOrEqual(0.5);
		expect(Math.abs((await box(page.locator(".command-bar-result .result-icon").first())).x - edge)).toBeLessThanOrEqual(0.5);
	});
}

test("scope chip prefixes sit in one fixed-width slot, centered on their label", async ({ page }) => {
	await openActions(page);

	const widths = new Set<number>();
	for (const chip of await page.locator(".scope-hint").all()) {
		const prefix = chip.locator(".scope-hint-prefix");
		if (!(await prefix.count())) continue;
		widths.add(Math.round((await box(prefix)).width * 100));
		const label = await textBox(chip.locator(".scope-hint-label"));
		expect(Math.abs(centerY(await textBox(prefix)) - centerY(label))).toBeLessThanOrEqual(0.5);
	}
	expect(widths.size).toBe(1);
});

test("key pills share one height and font with the labels, their text centered, the pill centered on its label", async ({ page }) => {
	await openActions(page);
	const labelFont = await page.locator(".footer-hint > span").first().evaluate((el) => getComputedStyle(el).fontFamily);

	const pills = [
		...(await page.locator(".command-bar-footer kbd").all()),
		...(await page.locator(".command-bar-result .result-helper").all()),
	];
	expect(pills.length).toBeGreaterThan(3);
	const heights = new Set<number>();
	for (const pill of pills) {
		await expect(pill).toHaveCSS("font-family", labelFont);
		const pillBox = await box(pill);
		heights.add(Math.round(pillBox.height * 100));
		const text = await textBox(pill);
		expect(Math.abs(centerY(text) - centerY(pillBox))).toBeLessThanOrEqual(0.5);
		expect(Math.abs(centerX(text) - centerX(pillBox))).toBeLessThanOrEqual(0.5);
	}
	expect(heights.size).toBe(1);

	// Same font and size, so equal text boxes mean the key and its label share a baseline.
	for (const hint of await page.locator(".footer-hint").all()) {
		const labelSize = await hint.locator("kbd + span").evaluate((el) => getComputedStyle(el).fontSize);
		await expect(hint.locator("kbd")).toHaveCSS("font-size", labelSize);
		const key = await textBox(hint.locator("kbd"));
		const label = await textBox(hint.locator("kbd + span"));
		expect(Math.abs(key.y - label.y)).toBeLessThanOrEqual(0.5);
		expect(Math.abs(key.height - label.height)).toBeLessThanOrEqual(0.5);
	}
});

test("footer hints that do not fit drop whole instead of showing a cut word", async ({ page }) => {
	await page.setViewportSize({ width: 1000, height: 640 });
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").fill("beta");
	await expect(page.locator(".footer-hints .footer-hint")).toHaveCount(7);

	const row = await box(page.locator(".footer-hints"));
	for (const hint of await page.locator(".footer-hints .footer-hint").all()) {
		const hintBox = await box(hint);
		const shownWhole = hintBox.x + hintBox.width <= row.x + row.width && hintBox.y < row.y + row.height;
		const hidden = hintBox.y >= row.y + row.height;
		expect(shownWhole || hidden, (await hint.textContent()) ?? "").toBe(true);
	}
});

test("reduced motion stills the footer like the rest of the bar", async ({ page }) => {
	await openActions(page);

	for (const selector of [".command-bar", ".command-bar-results", ".command-bar-footer"]) {
		await expect(page.locator(selector), selector).toHaveCSS("animation-name", "none");
	}
});

test("monogram tiles use the labels' font", async ({ page }) => {
	await openActions(page);
	await page.locator(".command-bar-input").fill("beta");
	const labelFont = await page.locator(".result-title").first().evaluate((el) => getComputedStyle(el).fontFamily);

	await expect(page.locator(".result-icon-letter, .result-favicon-fallback").first()).toHaveCSS("font-family", labelFont);
});
