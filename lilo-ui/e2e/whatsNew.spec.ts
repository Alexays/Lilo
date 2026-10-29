import { readFileSync } from "node:fs";
import { expect, test, type Page } from "@playwright/test";
import { bootChrome, type FakeHostWorld } from "./fakeHost";
import { initialWorld } from "./fixtures";
import type { ReleaseNotes } from "../src/components/whatsnew/releaseNotes";
import { createHash } from "node:crypto";
import { generatedReleaseEditorial } from "../src/components/whatsnew/releaseNotes";

test("0.8.0 MP4 and still work together, replay from cache and stop when closed", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	const source = new URL("../../site/src/assets/releases/0.8.0/", import.meta.url);
	const archive = JSON.parse(readFileSync(new URL("capture.json", source), "utf-8"));
	const presentation = JSON.parse(readFileSync(new URL("presentation.json", source), "utf-8"));
	const notes: ReleaseNotes = { version: "0.8.0", date: "2026-10-28", groups: [{ kind: "Added", entries: ["Choose and switch shared tabs."] }], editorial: { en: generatedReleaseEditorial(archive, "en", presentation.media) } };
	let reads = 0;
	await page.route("**/release-media/*-remotion.*", route => {
		const name = new URL(route.request().url()).pathname.split("/").at(-1)!;
		if (name.endsWith(".mp4")) reads += 1;
		return route.fulfill({ body: readFileSync(new URL(name, source)), contentType: name.endsWith(".mp4") ? "video/mp4" : "image/png" });
	});
	await bootReleaseChrome(page, initialWorld(), undefined, notes);
	await openWhatsNew(page, false, "0.8.0");
	const still = page.locator(".whats-new .release-image");
	await expect(still.locator("img")).toHaveJSProperty("naturalWidth", 1600);
	await expect(still.getByRole("button")).toHaveCount(0);
	const player = page.locator(".whats-new .release-recording");
	await player.scrollIntoViewIfNeeded();
	expect(reads).toBe(0);
	const button = player.getByRole("button");
	await button.focus();
	await page.keyboard.press("Enter");
	const video = player.locator("video");
	await expect(video).toHaveJSProperty("videoWidth", 1600);
	await expect(video).toHaveJSProperty("controls", true);
	await expect.poll(() => video.evaluate(node => (node as HTMLVideoElement).currentTime)).toBeGreaterThan(0.1);
	await video.evaluate(node => { const movie = node as HTMLVideoElement; movie.pause(); movie.currentTime = 6; movie.muted = false; });
	await expect(video).toHaveJSProperty("muted", false);
	await expect.poll(() => video.evaluate(node => (node as HTMLVideoElement).currentTime)).toBeGreaterThanOrEqual(6);
	await video.evaluate(node => { const movie = node as HTMLVideoElement; movie.currentTime = movie.duration - 0.1; return movie.play(); });
	await expect(video).toHaveJSProperty("ended", true);
	await expect(video).toBeVisible();
	await video.evaluate(node => (node as HTMLVideoElement).play());
	await expect(video).toHaveJSProperty("paused", false);
	await page.locator(".whats-new-body").evaluate(node => { node.scrollTop = 0; });
	await expect(video).toHaveCount(0);
	await player.scrollIntoViewIfNeeded();
	await button.click();
	await expect(video).toHaveJSProperty("videoWidth", 1600);
	await expect.poll(() => video.evaluate(node => (node as HTMLVideoElement).currentTime)).toBeGreaterThan(0.1);
	expect(reads).toBe(1);
	const activeMovie = await video.elementHandle();
	await page.keyboard.press("Escape");
	await expect(page.getByRole("dialog")).toHaveCount(0);
	await expect.poll(() => activeMovie?.evaluate(node => node instanceof HTMLVideoElement && node.paused)).toBe(true);
	await openWhatsNew(page, false, "0.8.0");
	await expect(page.locator(".whats-new video")).toHaveCount(0);
});

const release: ReleaseNotes = {
	version: "0.6.0", date: "2026-01-15",
	groups: [
		{ kind: "Added", entries: ["Unread counts on tabs and favorites.", "More reliable calls."] },
		{ kind: "Fixed", entries: ["Restore your saved session."] },
	],
	editorial: {
		en: {
			headline: "A little more in the loop.", description: "A few improvements.",
			highlights: [
				{ illustration: "unread", title: "Catch what you missed.", description: "Unread counts on your tabs." },
				{ illustration: "calls", title: "Stay in the conversation.", description: "Smoother video calls." },
			],
		},
		fr: {
			headline: "Toujours dans la boucle.", description: "De petites améliorations.",
			highlights: [{ illustration: "unread", title: "Ne manquez plus un message.", description: "Les messages non lus dans vos onglets." }],
		},
	},
};

async function bootReleaseChrome(page: Page, world: FakeHostWorld = initialWorld(), ready?: string, notes = release) {
	// Keep interaction tests stable when the real release's bundled resource changes.
	let resourceReads = 0;
	await page.route("**/release-notes.json", (route) => { resourceReads++; return route.fulfill({ json: notes }); });
	await bootChrome(page, world, ready);
	return () => resourceReads;
}

async function openWhatsNew(page: Page, automatic = false, version = "0.6.0") {
	await page.evaluate(({ automatic, version }) => window.__lilo!.receive({ event: "openWhatsNew", automatic, version }), { automatic, version });
}

test("the sheet presents installed highlights, all changes and one acknowledgment", async ({ page }) => {
	const resourceReads = await bootReleaseChrome(page);
	await openWhatsNew(page, true);
	const dialog = page.getByRole("dialog", { name: "A little more in the loop." });
	await expect(dialog).toBeVisible();
	await expect(dialog.getByRole("heading", { name: "Catch what you missed." })).toBeVisible();
	await expect(dialog.getByRole("heading", { name: "Stay in the conversation." })).toBeVisible();
	await openWhatsNew(page, true);
	await expect(page.getByRole("dialog")).toHaveCount(1);
	await expect.poll(() => page.evaluate(() => window.__sentCommands!.filter((item) => item.action === "whatsNewPresented").length)).toBe(1);
	await dialog.locator("summary").click();
	await expect(dialog.getByRole("listitem")).toHaveCount(3);
	await expect(dialog.getByText("Added", { exact: true })).toBeVisible();
	await dialog.getByRole("button", { name: "Back to browsing" }).click();
	await expect(dialog).toHaveCount(0);
	await expect.poll(() => page.evaluate(() => window.__sentCommands!.some((item) => item.action === "dismissWhatsNew"))).toBe(true);
	await openWhatsNew(page);
	await expect(dialog).toBeVisible();
	expect(resourceReads()).toBe(1);
});

test("bundled recordings wait for explicit playback with Reduce Motion and stop on close", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	const notes = structuredClone(release);
	if (!notes.editorial?.en) throw new Error("Missing test release copy");
	const source = new URL("./fixtures/", import.meta.url);
	for (const [extension, contentType] of [["png", "image/png"], ["webp", "image/webp"]]) {
		await page.route(`**/release-media/playback-fixture.${extension}`, route => route.fulfill({ contentType, body: readFileSync(new URL(`playback.${extension}`, source)) }));
	}
	const media = { poster: "playback-fixture.png", recording: "playback-fixture.webp", durationMs: 3400, width: 320, height: 200 };
	notes.editorial.en.highlights[0].media = { ...media, poster: `/release-media/${media.poster}`, recording: `/release-media/${media.recording}` };
	const requested: string[] = [];
	page.on("request", request => requested.push(request.url()));
	await bootReleaseChrome(page, initialWorld(), undefined, notes);
	await openWhatsNew(page);
	const player = page.locator(".whats-new .release-recording");
	await player.scrollIntoViewIfNeeded();
	const image = player.locator("img");
	await expect(image).toHaveJSProperty("naturalWidth", media.width);
	const button = player.getByRole("button");
	await expect(button).toHaveAttribute("aria-pressed", "false");
	expect(requested.some(url => url.endsWith(`/release-media/${media.recording}`))).toBe(false);
	await button.focus();
	await page.keyboard.press("Enter");
	await expect(button).toHaveAttribute("aria-pressed", "true");
	await expect(image).toHaveAttribute("src", /^blob:/);
	await expect(image).toHaveJSProperty("complete", true);
	const pixels = async () => createHash("sha256").update(await image.screenshot()).digest("hex");
	const firstFrame = await pixels();
	await expect.poll(pixels, { timeout: 3000 }).not.toBe(firstFrame);
	await expect(button).toHaveAttribute("aria-pressed", "false", { timeout: 17000 });
	await page.keyboard.press("Enter");
	await expect(button).toHaveAttribute("aria-pressed", "true");
	await expect(image).toHaveAttribute("src", /^blob:/);
	await expect(image).toHaveJSProperty("complete", true);
	await expect.poll(pixels, { timeout: 1500 }).toBe(firstFrame);
	await page.keyboard.press("Escape");
	await expect(page.getByRole("dialog")).toHaveCount(0);
	await openWhatsNew(page);
	await expect(page.locator(".whats-new .release-recording button")).toHaveAttribute("aria-pressed", "false");
});

test("Escape closes the sheet and focus stays inside until it closes", async ({ page }) => {
	await bootReleaseChrome(page);
	// A real chrome control is the return target; the native host separately owns page/terminal focus.
	const focusTarget = page.locator('.tab-item[data-tab-id="tab-beta"]').first();
	await focusTarget.focus();
	await openWhatsNew(page);
	const dialog = page.getByRole("dialog");
	await expect(dialog).toBeVisible();
	for (const key of ["Tab", "Tab", "Tab", "Tab", "Shift+Tab"]) {
		await page.keyboard.press(key);
		await expect.poll(() => dialog.evaluate((node) => node.contains(document.activeElement))).toBe(true);
	}
	await page.keyboard.press("Escape");
	await expect(dialog).toHaveCount(0);
	await expect(focusTarget).toBeFocused();
});

test("Escape leaves the settings surface underneath the dialog open", async ({ page }) => {
	await bootReleaseChrome(page);
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
	await openWhatsNew(page);
	await expect(page.getByRole("dialog")).toBeVisible();
	await page.keyboard.press("Escape");
	await expect(page.getByRole("dialog")).toHaveCount(0);
	await expect(page.locator(".ui-shell-frame")).toBeVisible();
});

test("Escape leaves the screenshot save menu underneath the dialog open", async ({ page }) => {
	await bootReleaseChrome(page);
	await page.evaluate(() => window.__lilo!.receive({ event: "screenshotCapturing" }));
	await page.locator('.screenshot-panel [aria-label="Save options"]').waitFor();
	await page.evaluate(() => window.__lilo!.receive({ event: "screenshotCaptured", id: "sample", url: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='800' height='500'/%3E", filename: "sample.png" }));
	await page.locator('.screenshot-panel [aria-label="Save options"]').click();
	await expect(page.locator(".save-menu")).toBeVisible();
	await openWhatsNew(page);
	await expect(page.locator("dialog[open]")).toBeVisible();
	await page.keyboard.press("Escape");
	await expect(page.locator("dialog[open]")).toHaveCount(0);
	await expect(page.locator(".save-menu")).toBeVisible();
});

test("automatic highlights wait for startup recovery to be dismissed", async ({ page }) => {
	await bootReleaseChrome(page);
	await page.evaluate(() => window.__lilo!.receive({ event: "sessionRestoreDegraded", spaceName: "Sample space" }));
	await openWhatsNew(page, true);
	await expect(page.getByRole("dialog")).toHaveCount(0);
	await page.getByRole("button", { name: "Close", exact: true }).click();
	await expect(page.getByRole("dialog")).toBeVisible();
});

test("a mismatched release suppresses automatic highlights and manual opening is truthful", async ({ page }) => {
	await bootReleaseChrome(page);
	await openWhatsNew(page, true, "9.0.0");
	await expect.poll(() => page.evaluate(() => window.__sentCommands!.some((item) => item.action === "dismissWhatsNew"))).toBe(true);
	await expect(page.getByRole("dialog")).toHaveCount(0);
	await openWhatsNew(page, false, "9.0.0");
	const dialog = page.getByRole("dialog");
	await expect(dialog).toBeVisible();
	await expect(dialog.getByText("Lilo 9.0.0", { exact: true })).toBeVisible();
	await expect(dialog.getByRole("heading", { name: "Catch what you missed." })).toHaveCount(0);
	await expect(dialog.getByText("Release notes aren’t available in this build.")).toBeVisible();
});

for (const tabPosition of ["left", "right", "top", "bottom"] as const) {
	test(`the ${tabPosition} layout keeps French dismissal reachable in a short window`, async ({ page }) => {
		await page.setViewportSize({ width: 780, height: 470 });
		await page.emulateMedia({ colorScheme: "dark", reducedMotion: "reduce" });
		await bootReleaseChrome(page, { ...initialWorld(), tabPosition }, tabPosition === "top" || tabPosition === "bottom" ? ".tab-strip .strip-tab" : undefined);
		await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "fr" } }));
		await openWhatsNew(page);
		const dialog = page.getByRole("dialog");
		await expect(dialog.getByRole("button", { name: "Reprendre la navigation" })).toBeVisible();
		const button = dialog.getByRole("button", { name: "Reprendre la navigation" });
		const bounds = await button.boundingBox();
		expect(bounds!.y).toBeGreaterThanOrEqual(0);
		expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(470);
		await dialog.locator("summary").click();
		await expect(dialog.getByRole("listitem")).toHaveCount(3);
		await expect(button).toBeVisible();
		await button.click();
		await expect(dialog).toHaveCount(0);
	});
}

test("a hidden sidebar still centers the sheet in the available content", async ({ page }) => {
	await bootReleaseChrome(page);
	await page.evaluate(() => window.__lilo!.receive({ event: "sidebarVisibilityChanged", visible: false, width: 260 }));
	await openWhatsNew(page);
	const dialog = page.getByRole("dialog");
	await expect(dialog).toBeVisible();
	const sheet = await dialog.locator(".whats-new-sheet").boundingBox();
	expect(sheet!.x + sheet!.width / 2).toBeCloseTo(page.viewportSize()!.width / 2, 0);
	await dialog.getByRole("button", { name: "Close" }).click();
	await expect(dialog).toHaveCount(0);
});

test("a maintenance release opens all of its notes without older feature claims", async ({ page }) => {
	await bootReleaseChrome(page, initialWorld(), undefined, { ...release, editorial: null });
	await openWhatsNew(page, true);
	const dialog = page.getByRole("dialog");
	await expect(dialog.getByRole("listitem")).toHaveCount(3);
	await expect(dialog.locator("details")).toHaveAttribute("open", "");
	await expect(dialog.locator(".release-highlight")).toHaveCount(0);
});

for (const [locale, title, continueLabel] of [
	["es", "Novedades de Lilo", "Volver a navegar"],
	["pt-BR", "Novidades do Lilo", "Voltar à navegação"],
	["ru", "Что нового в Lilo", "Вернуться к просмотру"],
	["zh-Hans", "Lilo 更新内容", "继续浏览"],
]) {
	test(`the maintenance sheet follows the ${locale} app language`, async ({ page }) => {
		await bootReleaseChrome(page, initialWorld(), undefined, { ...release, editorial: null });
		await page.evaluate((locale) => window.__lilo!.receive({ event: "settingsLoaded", settings: { locale } }), locale);
		await openWhatsNew(page);
		const dialog = page.getByRole("dialog", { name: title });
		await expect(dialog).toBeVisible();
		await expect(dialog.getByRole("listitem")).toHaveCount(3);
		await dialog.getByRole("button", { name: continueLabel }).click();
		await expect(dialog).toHaveCount(0);
	});
}

for (const automatic of [true, false]) {
	test(`a screen-sharing decision keeps its priority over ${automatic ? "automatic" : "manual"} highlights`, async ({ page }) => {
		await bootReleaseChrome(page);
		await openWhatsNew(page);
		await expect(page.locator("dialog[open]")).toBeVisible();
		await page.getByRole("button", { name: "Back to browsing" }).click();
		await page.evaluate(() => window.__lilo!.receive({ event: "tabSharePickerRequested", requestId: "request-share", origin: "meet.example.com", shareableTabIds: ["tab-alpha"] }));
		await expect(page.locator(".tab-share-panel")).toBeVisible();
		await openWhatsNew(page, automatic);
		await page.evaluate(() => new Promise(requestAnimationFrame));
		await expect(page.locator("dialog[open]")).toHaveCount(0);
		await page.keyboard.press("Escape");
		await expect(page.locator(".tab-share-panel")).toHaveCount(0);
		await expect(page.locator("dialog[open]")).toBeVisible();
	});

	test(`a pending site permission keeps its priority over ${automatic ? "automatic" : "manual"} highlights`, async ({ page }) => {
		await bootReleaseChrome(page);
		await openWhatsNew(page);
		await expect(page.getByRole("dialog")).toBeVisible();
		await page.getByRole("dialog").getByRole("button", { name: "Back to browsing" }).click();
		await expect(page.getByRole("dialog")).toHaveCount(0);
		await page.evaluate(() => window.__lilo!.receive({ event: "permissionRequest", requestId: "request-camera", tabId: "tab-alpha", type: "camera", origin: "meet.example.com" }));
		await openWhatsNew(page, automatic);
		await page.evaluate(() => new Promise(requestAnimationFrame));
		await expect(page.getByRole("dialog")).toHaveCount(0);
		await page.locator(".url-drawer.open").getByRole("button", { name: "Allow", exact: true }).click();
		await expect(page.getByRole("dialog")).toBeVisible();
	});
}
