import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { treeItem } from "../src/stores/testFixtures";

/** WCAG contrast of two computed CSS colors (rgb, rgba or color(srgb) over an opaque base). */
async function ratio(page: Page, foreground: string, background: string): Promise<number> {
	return page.evaluate(([fg, bg]) => {
		// A color-mix() computes to color(srgb r g b), channels from 0 to 1.
		const parse = (value: string) => {
			const channels = (value.match(/[\d.]+/g) ?? ["0", "0", "0"]).slice(0, 3).map(Number);
			return value.startsWith("color(") ? channels.map((c) => c * 255) : channels;
		};
		const channel = (c: number) => {
			const v = c / 255;
			return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
		};
		const luminance = (rgb: number[]) => 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
		const [a, b] = [luminance(parse(fg)), luminance(parse(bg))].sort((x, y) => y - x);
		return (a + 0.05) / (b + 0.05);
	}, [foreground, background]);
}

/** How far a row's (possibly translucent) background stands out from the sidebar, as a contrast ratio. */
async function rowStrength(page: Page, selector: string): Promise<number> {
	const [row, sidebar] = await page.locator(selector).first().evaluate((el) => {
		const canvas = document.createElement("canvas").getContext("2d")!;
		const sidebarBg = getComputedStyle(document.querySelector(".sidebar")!).backgroundColor;
		canvas.fillStyle = sidebarBg;
		canvas.fillRect(0, 0, 1, 1);
		canvas.fillStyle = getComputedStyle(el).backgroundColor;
		canvas.fillRect(0, 0, 1, 1);
		const [r, g, b] = canvas.getImageData(0, 0, 1, 1).data;
		return [`rgb(${r}, ${g}, ${b})`, sidebarBg];
	});
	return ratio(page, row, sidebar);
}

for (const colorScheme of ["light", "dark"] as const) {
	test(`the active row stands out more than a hovered one in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
		await bootChrome(page, initialWorld());
		await page.locator('.tab-list [data-tab-id="tab-beta"]').hover();

		// The row eases into its hover color: read it once the transition is over.
		await expect.poll(() => rowStrength(page, '.tab-list [data-tab-id="tab-beta"]')).toBeGreaterThan(1.02);
		await page.waitForTimeout(300);
		const hovered = await rowStrength(page, '.tab-list [data-tab-id="tab-beta"]');
		const active = await rowStrength(page, ".tab-item.active:not(.travel-hold)");
		expect(active - 1).toBeGreaterThan((hovered - 1) * 1.5);
	});
}

test("an open folder's icon reads on its background", async ({ page }) => {
	await page.emulateMedia({ colorScheme: "dark" });
	// The fake host has no folder model, so the folder is pushed as a plain state snapshot.
	const world = initialWorld();
	const folder = { id: "folder-docs", spaceId: SPACE_1, name: "Docs", color: "#8a9ba8", isCollapsed: false };
	const tabIds = ["tab-beta", "tab-gamma"];
	await bootChrome(page, world);
	await page.evaluate(
		(state) => window.__lilo!.receive({
			event: "browserStateChanged",
			changedSpaceId: state.spaceId,
			activeTabId: state.activeTabId,
			states: [state],
		}),
		{
			spaceId: SPACE_1,
			activeTabId: "tab-alpha",
			tabs: world.tabsBySpace[SPACE_1],
			folders: [folder],
			treeItems: [
				...world.treeItemsBySpace[SPACE_1].filter((item) => !tabIds.includes(item.itemId)),
				treeItem(folder.id, SPACE_1, 5, "unpinned", "folder"),
				...tabIds.map((id, index) => treeItem(id, SPACE_1, index, "unpinned", "tab", folder.id)),
			],
		},
	);
	await page.locator(".folder-row").first().waitFor();

	const icon = await page.locator(".folder-row .folder-icon").first().evaluate((el) => getComputedStyle(el).color);
	const background = await page.locator(".folder-open-rail .folder-drop-zone").first().evaluate((el) => getComputedStyle(el).backgroundColor);

	expect(await ratio(page, icon, background)).toBeGreaterThanOrEqual(3);
});

test("an open folder's papers stand out from its background in light mode", async ({ page }) => {
	await page.emulateMedia({ colorScheme: "light" });
	const world = initialWorld();
	world.foldersBySpace = { [SPACE_1]: [{ id: "folder-docs", spaceId: SPACE_1, name: "Docs", color: "#4a90d9", isCollapsed: false }] };
	world.treeItemsBySpace[SPACE_1] = [
		...world.treeItemsBySpace[SPACE_1].filter((item) => item.itemId !== "tab-beta"),
		treeItem("folder-docs", SPACE_1, 5, "unpinned", "folder"),
		treeItem("tab-beta", SPACE_1, 6, "unpinned", "tab", "folder-docs"),
	];
	await bootChrome(page, world);
	await page.locator(".folder-icon--open").waitFor();

	const paper = await page.locator(".folder-file-fill").first().evaluate((el) => getComputedStyle(el).fill);
	const background = await page.locator(".folder-open-rail .folder-drop-zone").first().evaluate((el) => getComputedStyle(el).backgroundColor);
	expect(await ratio(page, paper, background)).toBeGreaterThanOrEqual(1.5);
});

async function cssColor(page: Page, selector: string, property: "color" | "backgroundColor"): Promise<string> {
	return page.locator(selector).first().evaluate((el, prop) => getComputedStyle(el)[prop as "color"], property);
}

test("the active capture button is solid accent with a readable icon", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.locator(".url-trigger").hover();
	await page.locator(".url-screenshot-btn").click();

	const accent = await page.locator(".url-screenshot-btn.active").evaluate((el) => {
		const probe = document.createElement("span");
		probe.style.color = "var(--accent)";
		el.appendChild(probe);
		const value = getComputedStyle(probe).color;
		probe.remove();
		return value;
	});
	// The button eases into its active color: read it once the transition is over.
	await expect.poll(() => cssColor(page, ".url-screenshot-btn.active", "backgroundColor")).toBe(accent);
	const background = await cssColor(page, ".url-screenshot-btn.active", "backgroundColor");
	expect(await ratio(page, await cssColor(page, ".url-screenshot-btn.active", "color"), background)).toBeGreaterThanOrEqual(4.5);
});

test("a closed tab's title reads at full strength and says it sleeps without color", async ({ page }) => {
	const world = initialWorld();
	// A pinned tab stays in the sidebar while it sleeps.
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].map((tab) => tab.id === "tab-home" ? { ...tab, isClosed: true } : tab);
	await bootChrome(page, world);
	const closed = ".tab-item.closed";
	await page.locator(closed).first().waitFor();

	expect(await page.locator(closed).first().evaluate((el) => getComputedStyle(el).opacity)).toBe("1");
	expect(await page.locator(`${closed} .tab-title`).first().evaluate((el) => getComputedStyle(el).fontStyle)).toBe("italic");
	const sidebar = await cssColor(page, ".sidebar", "backgroundColor");
	expect(await ratio(page, await cssColor(page, `${closed} .tab-title`, "color"), sidebar)).toBeGreaterThanOrEqual(4.5);
	await page.locator(closed).first().hover();
	expect(await ratio(page, await cssColor(page, `${closed} .tab-title`, "color"), sidebar)).toBeGreaterThanOrEqual(4.5);
});

for (const color of ["#fff4cc", "#ffffff", "#20242e", "#ff00ff", "#f0a8c8"]) {
	for (const colorScheme of ["light", "dark"] as const) {
		test(`the active tab's title reads on a ${color} Space in ${colorScheme} mode`, async ({ page }) => {
			// Reduced motion: the row's background transition must not be read halfway.
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = initialWorld();
			world.spaces[0].color = color;
			await bootChrome(page, world);
			const active = ".tab-item.active:not(.travel-hold)";
			await page.locator(active).first().waitFor();

			const title = await cssColor(page, `${active} .tab-title`, "color");
			const row = await cssColor(page, active, "backgroundColor");
			expect(await ratio(page, title, row)).toBeGreaterThanOrEqual(4.5);
		});
	}
}

for (const color of ["#20242e", "#000000", "#4a90d9"]) {
	for (const colorScheme of ["light", "dark"] as const) {
		test(`a hung tab's timer reads on a ${color} Space in ${colorScheme} mode`, async ({ page }) => {
			await page.emulateMedia({ colorScheme });
			const world = initialWorld();
			world.spaces[0].color = color;
			await bootChrome(page, world);
			await page.evaluate(() => window.__lilo!.receive({
				event: "pageResponsivenessChanged", tabId: "tab-beta", responsive: false, host: "example.com", site: "example.com",
			}));
			const timer = '[data-tab-id="tab-beta"] .hang-timer';
			await page.locator(timer).waitFor();

			const sidebar = await cssColor(page, ".sidebar", "backgroundColor");
			expect(await ratio(page, await cssColor(page, timer, "color"), sidebar)).toBeGreaterThanOrEqual(4.5);
		});
	}
}

test("the screenshot panel's primary button and labels read", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "screenshotCaptured", id: "x", url: "data:image/png;base64,iVBORw0KGgo=", filename: "x.png" }));
	await page.locator(".screenshot-panel .btn.primary").first().waitFor();

	const button = ".screenshot-panel .btn.primary";
	expect(await ratio(page, await cssColor(page, button, "color"), await cssColor(page, button, "backgroundColor"))).toBeGreaterThanOrEqual(4.5);
	const card = await cssColor(page, ".screenshot-panel .card", "backgroundColor");
	expect(await ratio(page, await cssColor(page, ".screenshot-panel .group-label", "color"), card)).toBeGreaterThanOrEqual(4.5);
});

/**
 * WCAG contrast of an element's text against what lies behind it: translucent layers are composited down to the
 * first opaque one, and the opacity of the elements in between fades the text.
 */
async function textContrast(page: Page, selector: string): Promise<number> {
	return page.locator(selector).first().evaluate((el) => {
		const context = document.createElement("canvas").getContext("2d", { willReadFrequently: true })!;
		const rgba = (value: string): number[] => {
			context.clearRect(0, 0, 1, 1);
			context.fillStyle = value;
			context.fillRect(0, 0, 1, 1);
			const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data;
			return [r, g, b, a / 255];
		};
		const over = (top: number[], bottom: number[]) => [0, 1, 2].map((i) => top[i] * top[3] + bottom[i] * (1 - top[3]));
		const layers: number[][] = [];
		let opacity = 1;
		for (let node: Element | null = el; node; node = node.parentElement) {
			const layer = rgba(getComputedStyle(node).backgroundColor);
			if (layer[3] > 0) layers.push(layer);
			if (layer[3] === 1) break;
			opacity *= Number(getComputedStyle(node).opacity);
		}
		const background = layers.reverse().reduce((below, layer) => over(layer, below), [255, 255, 255]);
		const color = rgba(getComputedStyle(el).color);
		const text = over([color[0], color[1], color[2], color[3] * opacity], background);
		const channel = (c: number) => {
			const v = c / 255;
			return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
		};
		const luminance = (rgb: number[]) => 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
		const [a, b] = [luminance(text), luminance(background)].sort((x, y) => y - x);
		return (a + 0.05) / (b + 0.05);
	});
}

for (const colorScheme of ["light", "dark"] as const) {
	test(`the command bar's scope chips and selected row read in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
		await page.locator(".command-bar-result.selected .result-subtitle").waitFor();

		expect(await textContrast(page, ".scope-hint:not(.selected)")).toBeGreaterThanOrEqual(4.5);
		expect(await textContrast(page, ".command-bar-result.selected .result-subtitle")).toBeGreaterThanOrEqual(4.5);
	});

	test(`the command bar's match highlights read in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
		await page.locator(".command-bar-input").fill("beta");
		await page.locator(".command-bar-result.selected .result-hl").first().waitFor();

		expect(await textContrast(page, ".command-bar-result.selected .result-hl")).toBeGreaterThanOrEqual(4.5);
	});
}

for (const color of ["#4a90d9", "#fff4cc", "#20242e", "#ff00ff"]) {
	for (const colorScheme of ["light", "dark"] as const) {
		test(`the address path and the Copied feedback read on a ${color} Space in ${colorScheme} mode`, async ({ page }) => {
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = initialWorld();
			world.spaces[0].color = color;
			await bootChrome(page, world);

			expect(await textContrast(page, ".url-path")).toBeGreaterThanOrEqual(4.5);
			await page.evaluate(() => window.__lilo!.receive({ event: "urlCopied" }));
			await page.locator(".url-host.feedback").waitFor();
			expect(await textContrast(page, ".url-host.feedback")).toBeGreaterThanOrEqual(4.5);
		});
	}
}

for (const colorScheme of ["light", "dark"] as const) {
	test(`the find bar's no-match notice reads in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
		await bootChrome(page, initialWorld());
		// The find bar mounts with the deferred chrome, a beat after boot.
		await expect(async () => {
			await page.evaluate(() => window.__lilo!.receive({ event: "toggleFindBar", query: "zz" }));
			await expect(page.locator(".find-bar")).toBeVisible({ timeout: 200 });
		}).toPass();
		await page.evaluate(() => window.__lilo!.receive({ event: "findInPageResult", query: "zz", matchFound: false }));
		await expect(page.locator(".find-status")).not.toBeEmpty();

		expect(await textContrast(page, ".find-status")).toBeGreaterThanOrEqual(4.5);
	});
}

test("prefers-contrast still overrides muted text", async ({ page }) => {
	await page.emulateMedia({ contrast: "more" });
	await bootChrome(page, initialWorld());

	const muted = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--text-muted").trim());
	expect(muted).not.toBe("");
});

for (const colorScheme of ["light", "dark"] as const) {
	test(`Increase contrast firms secondary text, separators and the focus ring in ${colorScheme} mode`, async ({ page }) => {
		const tokens = () => page.evaluate(() => {
			const style = getComputedStyle(document.documentElement);
			return ["--text-secondary", "--separator", "--focus-outline"].map((name) => style.getPropertyValue(name).trim());
		});
		await page.emulateMedia({ colorScheme, contrast: "no-preference" });
		await bootChrome(page, initialWorld());
		const [secondary, separator] = await tokens();

		await page.emulateMedia({ colorScheme, contrast: "more" });
		const [moreSecondary, moreSeparator, focusOutline] = await tokens();

		expect(moreSecondary).not.toBe(secondary);
		expect(moreSeparator).not.toBe(separator);
		expect(focusOutline).not.toContain("transparent");
	});
}

async function openSettingsAt(page: Page, section: string): Promise<void> {
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: section }).click();
}

for (const colorScheme of ["light", "dark"] as const) {
	test.describe(`in ${colorScheme} mode`, () => {
		test.use({ colorScheme, reducedMotion: "reduce" });

		test("a danger button's label reads", async ({ page }) => {
			await bootChrome(page, initialWorld());
			await page.evaluate(() => window.__lilo!.receive({ event: "openClearBrowsingData" }));
			expect(await textContrast(page, ".ui-button.danger")).toBeGreaterThanOrEqual(4.5);
		});

		test("a confirm sheet's danger button reads", async ({ page }) => {
			await bootChrome(page, initialWorld());
			await page.evaluate(() => window.__lilo!.receive({ event: "openProcessManager" }));
			await page.locator(".process-panel").waitFor();
			await page.evaluate(() =>
				window.__lilo!.receive({
					event: "processSnapshotUpdated",
					processes: [
						{
							id: "p1",
							kind: "webContent",
							pid: 100,
							tabs: [{ id: "tab-alpha", spaceId: "space-1", title: "Alpha", url: "https://example.com/alpha", lifecycle: "active", isAudioPlaying: false, isMicrophoneActive: false, isCameraActive: false, isScreenSharing: false }],
							metrics: { residentSizeBytes: 100_000_000 },
							webProcessStateLabel: "",
						},
					],
				}),
			);
			await page.locator(".process-panel .tab-row").first().click();
			await page.locator(".process-panel .small-button.danger").click();
			const confirm = page.locator(".sheet-btn-danger");
			await expect(confirm).toBeVisible();
			expect(await textContrast(page, ".sheet-btn-danger")).toBeGreaterThanOrEqual(4.5);
		});

		test("a success badge reads", async ({ page }) => {
			await bootChrome(page, initialWorld());
			await openSettingsAt(page, "General");
			await page.evaluate(() => window.__lilo!.receive({ event: "defaultBrowserStatusLoaded", isDefault: true, shouldInvite: false }));
			expect(await textContrast(page, ".ui-badge.success")).toBeGreaterThanOrEqual(4.5);
		});

		test("the internal debug flags' disclosure reads", async ({ page }) => {
			await bootChrome(page, initialWorld());
			await openSettingsAt(page, "Advanced");
			await page.evaluate(() => window.__lilo!.receive({
				event: "featureFlagsLoaded",
				flags: [{ key: "DebugThing", name: "Debug thing", details: "", kind: "debug", enabled: false, modified: false }],
			}));
			expect(await textContrast(page, ".ui-link-row[aria-expanded] .ui-list-row-title")).toBeGreaterThanOrEqual(4.5);
		});

		test("the onboarding's colored labels read", async ({ page }) => {
			await bootChrome(page, initialWorld());
			const receive = (message: Record<string, unknown>) => page.evaluate((msg) => window.__lilo!.receive(msg), message);
			await receive({ event: "onboardingState", show: true, step: 2, usage: "browse" });
			await receive({
				event: "importSourcesLoaded",
				sources: [
					{ id: "chrome", name: "Chrome", family: "chromium", iconDataURL: "", needsFullDiskAccess: false, profiles: [{ id: "Default", name: "Me", kinds: ["bookmarks", "history"], extensions: [] }] },
					{ id: "safari", name: "Safari", family: "safari", iconDataURL: "", needsFullDiskAccess: true, profiles: [] },
				],
			});
			expect(await textContrast(page, ".src.locked .hint"), "Allow access").toBeGreaterThanOrEqual(4.5);
			expect(await textContrast(page, "button.more[aria-expanded]"), "more options").toBeGreaterThanOrEqual(4.5);
			await page.locator("button.more[aria-expanded]").click();
			expect(await textContrast(page, ".chip:not(.off)"), "kind chip").toBeGreaterThanOrEqual(4.5);

			await page.locator("section.card .ob-foot .ob-btn.primary").click();
			await receive({ event: "importProgress", sourceId: "chrome", profileId: "Default", kind: "history", done: 0, total: 0 });
			// Polled: the label fades in.
			await expect.poll(() => textContrast(page, ".progress .step span"), { message: "import step" }).toBeGreaterThanOrEqual(4.5);
			await receive({ event: "importFinished", summary: [{ sourceId: "chrome", profileId: "Default", kind: "history", imported: 12 }] });
			expect(await textContrast(page, ".note.done"), "import done").toBeGreaterThanOrEqual(4.5);

			await receive({ event: "defaultBrowserStatusLoaded", isDefault: true, shouldInvite: false });
			await receive({ event: "onboardingState", show: true, step: 6, usage: "browse" });
			expect(await textContrast(page, ".ob-done"), "default browser done").toBeGreaterThanOrEqual(4.5);
		});

		test("a password manager not ready yet still reads", async ({ page }) => {
			await bootChrome(page, initialWorld());
			await page.evaluate(() => window.__lilo!.receive({ event: "onboardingState", show: true, step: 3, usage: "browse" }));
			for (const selector of [".manager.soon .ob-text", ".manager.soon .ob-text small", ".manager.soon .badge"]) {
				expect(await textContrast(page, selector), selector).toBeGreaterThanOrEqual(4.5);
			}
		});

		test("a search engine's error reads", async ({ page }) => {
			await bootChrome(page, initialWorld());
			await openSettingsAt(page, "General");
			await page.locator(".ui-link-row").filter({ hasText: "Search engines" }).click();
			await page.getByRole("textbox", { name: "Name" }).first().fill("");
			expect(await textContrast(page, ".engine-error")).toBeGreaterThanOrEqual(4.5);
		});
	});
}

test("the slowest startup step's time reads on the sidebar", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openDiagnostics" }));
	await page.locator(".diagnostics-panel").waitFor();
	await page.evaluate(() =>
		window.__lilo!.receive({
			event: "startupMetricsLoaded",
			summary: {},
			marks: ["launch", "ready"].map((event, index) => ({ id: event, timestamp: 0, event, totalMilliseconds: 100 + index * 300, deltaMilliseconds: 100 + index * 200 })),
			traces: [],
		}),
	);

	const slowest = ".waterfall-row.slowest .waterfall-value";
	await page.locator(slowest).waitFor();
	expect(await ratio(page, await cssColor(page, slowest, "color"), await cssColor(page, ".sidebar", "backgroundColor"))).toBeGreaterThanOrEqual(4.5);
});

for (const colorScheme of ["light", "dark"] as const) {
	test(`a failed download's error reads on the sidebar in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme });
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openDownloads" }));
		await page.locator(".downloads-panel").waitFor();
		await page.evaluate(() =>
			window.__lilo!.receive({
				event: "downloadsSnapshot",
				items: [{ id: 1, url: "https://example.com/a.zip", filename: "a.zip", bytesReceived: 1, totalBytes: 2, state: "interrupted", startedAt: Date.now() / 1000, error: "Network lost", fileMissing: false, source: "wk" }],
			}),
		);

		const error = ".download-row .row-meta.tone-error";
		await page.locator(error).waitFor();
		expect(await ratio(page, await cssColor(page, error, "color"), await cssColor(page, ".sidebar", "backgroundColor"))).toBeGreaterThanOrEqual(4.5);
	});
}

for (const color of ["#4a90d9", "#fff4cc", "#20242e", "#ff00ff", "#00c000"]) {
	for (const colorScheme of ["light", "dark"] as const) {
		test(`the cards over the page take the ${color} Space's accent and read in ${colorScheme} mode`, async ({ page }) => {
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = initialWorld();
			world.spaces[0].color = color;
			await bootChrome(page, world);
			const spaceAccent = await page.evaluate(() => {
				const probe = document.createElement("div");
				probe.style.color = "var(--sidebar-accent)";
				document.body.appendChild(probe);
				const value = getComputedStyle(probe).color;
				probe.remove();
				return value;
			});
			const receive = (message: Record<string, unknown>) => page.evaluate((msg) => window.__lilo!.receive(msg), message);

			await receive({ event: "pageResponsivenessChanged", tabId: "tab-alpha", responsive: false, host: "example.com", site: "example.com" });
			const reload = ".page-hang .ui-button.primary";
			await page.locator(reload).waitFor();
			expect(await cssColor(page, reload, "backgroundColor")).toBe(spaceAccent);
			expect(await textContrast(page, reload)).toBeGreaterThanOrEqual(4.5);
			await page.locator(reload).click();
			await receive({ event: "pageResponsivenessChanged", tabId: "tab-alpha", responsive: true, host: "example.com", site: "example.com" });
			await receive({ event: "pageResponsivenessChanged", tabId: "tab-alpha", responsive: false, host: "example.com", site: "example.com" });
			await page.locator(".page-hang .report").waitFor();
			expect(await textContrast(page, ".page-hang .report")).toBeGreaterThanOrEqual(4.5);

			await receive({ event: "tabSharePickerRequested", requestId: "r", origin: "meet.example.com", shareableTabIds: ["tab-alpha"] });
			await page.locator(".tab-share-current").waitFor();
			expect(await cssColor(page, ".tab-share-current", "backgroundColor")).toBe(spaceAccent);
			expect(await textContrast(page, ".tab-share-current")).toBeGreaterThanOrEqual(4.5);
		});

		test(`a copied capture's card reads on a ${color} Space in ${colorScheme} mode`, async ({ page }) => {
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = initialWorld();
			world.spaces[0].color = color;
			await bootChrome(page, world);
			await page.evaluate(() => window.__lilo!.receive({ event: "captureCopied", captureId: "c1", thumbURL: "", filename: "c1.png" }));
			const edit = ".capture-card .action.primary";
			await page.locator(edit).waitFor();
			await page.waitForFunction(() => document.querySelector(".capture-card")!.getAnimations().length === 0);

			// A mid or saturated accent takes a white label, its fill darkened until it reads.
			if (color === "#4a90d9" || color === "#ff00ff") expect(await cssColor(page, edit, "color")).toBe("rgb(255, 255, 255)");
			for (const selector of [edit, ".capture-card .action:not(.primary):not(.dismiss)", ".capture-card .dismiss", ".capture-card .badge"]) {
				expect(await textContrast(page, selector), selector).toBeGreaterThanOrEqual(4.5);
			}
			await page.locator(edit).hover();
			await page.waitForTimeout(100);
			expect(await textContrast(page, edit), "hovered Edit").toBeGreaterThanOrEqual(4.5);
		});
	}
}

for (const color of ["#4a90d9", "#20242e", "#ff00ff"]) {
	for (const colorScheme of ["light", "dark"] as const) {
		test(`an unselected segment reads on a ${color} Space in ${colorScheme} mode`, async ({ page }) => {
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = initialWorld();
			world.spaces[0].color = color;
			await bootChrome(page, world);
			await page.evaluate(() => window.__lilo!.receive({ event: "openDiagnostics" }));
			const unselected = ".diagnostics-panel .ui-segmented button:not(.active)";
			await page.locator(unselected).first().waitFor();

			expect(await textContrast(page, unselected)).toBeGreaterThanOrEqual(4.5);
		});
	}
}

for (const color of ["#4a90d9", "#fff4cc", "#20242e", "#ff00ff"]) {
	for (const colorScheme of ["light", "dark"] as const) {
		test(`a frozen tab's open row in the process manager reads on a ${color} Space in ${colorScheme} mode`, async ({ page }) => {
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = initialWorld();
			world.spaces[0].color = color;
			await bootChrome(page, world);
			await page.evaluate(() => window.__lilo!.receive({ event: "openProcessManager" }));
			await page.locator(".process-panel").waitFor();
			const tab = (id: string) => ({ id, spaceId: "space-1", title: id, url: `https://example.com/${id}`, lifecycle: "active", isAudioPlaying: false, isMicrophoneActive: false, isCameraActive: false, isScreenSharing: false });
			await page.evaluate(
				(tabs) => window.__lilo!.receive({
					event: "processSnapshotUpdated",
					processes: [{ id: "p", kind: "webContent", pid: 7, tabs, metrics: { residentSizeBytes: 300_000_000 }, webProcessStateLabel: "", webProcessIsResponsive: false }],
				}),
				[tab("tab-beta"), tab("tab-gamma")],
			);
			await page.locator(".process-panel .tab-row").first().click();

			for (const selector of [".tab-entry.expanded .tab-title", ".tab-entry.expanded .tab-state", ".tab-entry.expanded .favicon-fallback", ".details-url", ".details-meta", ".details .small-button.danger", ".reclaim .link-button"]) {
				if (await page.locator(selector).count() === 0) continue;
				expect(await textContrast(page, selector), selector).toBeGreaterThanOrEqual(4.5);
			}
		});

		test(`the diagnostics' link to the process manager reads on a ${color} Space in ${colorScheme} mode`, async ({ page }) => {
			await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
			const world = initialWorld();
			world.spaces[0].color = color;
			await bootChrome(page, world);
			await page.evaluate(() => window.__lilo!.receive({ event: "openDiagnostics" }));
			await page.locator(".diagnostics-panel .ui-segmented button").nth(1).click();

			expect(await textContrast(page, ".diagnostics-panel .link-button")).toBeGreaterThanOrEqual(4.5);
		});
	}
}

test("a dark glyph on transparency sits on a chip on a dark Space, an opaque icon keeps its own background", async ({ page }) => {
	const glyph = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGklEQVR4nGNgGAUYQE3F4z8+PGrAyDBgBAIAXBVkQdcEF9cAAAAASUVORK5CYII=";
	const opaque = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR4nGNQU/H4TwlmGDVg1IBRA4aLAQBkM5EQwEVXkAAAAABJRU5ErkJggg==";
	const world = initialWorld();
	world.spaces[0].color = "#363a75";
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].map((tab, index) =>
		index === 0 ? { ...tab, faviconDataURL: glyph } : index === 1 ? { ...tab, faviconDataURL: opaque } : tab,
	);
	await page.emulateMedia({ colorScheme: "dark" });
	await bootChrome(page, world);

	const [first, second] = world.tabsBySpace[SPACE_1];
	await expect(page.locator(`.tab-list [data-tab-id="${first.id}"] .site-favicon`)).toHaveClass(/has-chip/);
	await expect(page.locator(`.tab-list [data-tab-id="${second.id}"] .site-favicon`)).not.toHaveClass(/has-chip/);
});

test("a colored glyph on a light Space keeps no chip, even under the contrast floor", async ({ page }) => {
	const orange = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAANElEQVR4nGNgGLTg61KV/8iYbI0kGURIM0FDKDKAWM04DRkGBgx8LBBrCF7N+AwiWiPdAQAzuTLAHZyC9gAAAABJRU5ErkJggg==";
	const world = initialWorld();
	world.spaces[0].color = "#e2daf1";
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].map((tab, index) => (index === 0 ? { ...tab, faviconDataURL: orange } : tab));
	await page.emulateMedia({ colorScheme: "light" });
	await bootChrome(page, world);

	const favicon = page.locator(`.tab-list [data-tab-id="${world.tabsBySpace[SPACE_1][0].id}"] .site-favicon`);
	await expect(favicon.locator("img")).toHaveJSProperty("complete", true);
	await expect(favicon).not.toHaveClass(/has-chip/);
});
