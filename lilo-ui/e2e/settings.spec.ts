import { expect, test, type Locator } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("a new profile's color swatches are named, not read out as hex codes", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: "Tabs and spaces" }).click();

	await page.locator(".add-card").click();

	const swatches = page.locator(".new-swatch");
	await expect(swatches.first()).toHaveAttribute("aria-label", "Color 1");
	await expect(swatches.last()).toHaveAttribute("aria-label", `Color ${await swatches.count()}`);
});

test("the shortcuts' Reset all button shows its whole label beside the search field", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".ui-link-row").filter({ hasText: "Keyboard shortcuts" }).click();

	const reset = page.locator(".shortcuts-toolbar .ui-button");
	await expect(reset).toHaveText("Reset All");
	expect(await reset.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
});

test("a shortcut conflict moves focus to Replace, and Cancel gives it back to the row's keys", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openShortcuts" }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "shortcutsLoaded",
		groups: [{ title: "Tabs", items: [{ id: "tab.new", title: "New Tab", keys: ["⌘T"], custom: false }] }],
		controlTabOrder: "recent",
	}));
	const list = page.locator(".shortcuts-list");
	const keys = list.locator(".shortcut-keys");
	await expect(keys).toHaveAttribute("aria-label", "New Tab, ⌘T");

	await keys.click();
	await page.evaluate(() => window.__lilo!.receive({ event: "shortcutConflict", id: "tab.new", combo: "⌘w", keys: "⌘W", owner: "Close Tab" }));
	await expect(list.getByRole("button", { name: "Replace" })).toBeFocused();
	await expect(page.locator(".live-announcer")).toContainText("Close Tab");

	await list.getByRole("button", { name: "Cancel" }).click();
	await expect(keys).toBeFocused();
});

test("the agent tiles style their secondary buttons like the other agent rows", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { agentControlEnabled: "true" } }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "agentClientsLoaded",
		clients: [{ id: "claudeCode", configured: true, icon: null }],
		allowed: [{ name: "claude-code", displayName: "Claude Code", lastSeen: null, client: "claudeCode" }],
	}));
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();

	await expect(page.locator(".ui-shell-frame .agent-tile")).toHaveCount(1);
	await expect(page.locator(".ui-shell-frame [data-setting-id='agentOther'] .ui-list-row-title")).toHaveCount(1);
	const backgrounds = await page.locator(".ui-shell-frame .ui-button:not(.primary)").evaluateAll((els) => [...new Set(els.map((el) => getComputedStyle(el).backgroundColor))]);
	expect(backgrounds).toHaveLength(1);
});

test("search engines and link rules share their row actions, and engine fields line up", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "settingsLoaded",
		settings: { externalLinkRules: JSON.stringify([{ match: "host", pattern: "github.com", destination: "little" }]) },
	}));
	const look = (selector: string) => page.locator(selector).first().evaluate((el) => {
		const style = getComputedStyle(el);
		const svg = el.querySelector("svg")?.getBoundingClientRect();
		return [style.width, style.height, style.borderRadius, style.borderTopWidth, style.backgroundColor, Math.round(svg?.width ?? 0)];
	});
	const fieldRadius = (selector: string) => page.locator(selector).first().evaluate((el) => getComputedStyle(el).borderRadius);
	const ruleAction = await look('[data-rule-index="0"] .rule-actions > .ui-button:last-child');
	const ruleFieldRadius = await fieldRadius('[data-rule-index="0"] input');

	await page.locator(".ui-link-row").filter({ hasText: "Search engines" }).click();
	await expect(page.locator(".engine-row").first()).toBeVisible();
	expect(await look(".engine-row .engine-actions > .ui-button:last-child")).toEqual(ruleAction);
	expect(await fieldRadius(".engine-row input")).toBe(ruleFieldRadius);

	const rights = await page.locator(".engine-row .engine-fields").evaluateAll((els) => els.map((el) => el.getBoundingClientRect().right));
	expect(new Set(rights).size).toBe(1);
});

test("the feature flags' warning sits in a row and the debug flags fold behind a row", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: "Advanced" }).click();
	await page.evaluate(() => window.__lilo!.receive({
		event: "featureFlagsLoaded",
		flags: [{ key: "DebugThing", name: "Debug thing", details: "", kind: "debug", enabled: false, modified: true }],
	}));

	const frame = page.locator(".ui-shell-frame");
	await expect(frame.locator(".ui-list-row").filter({ hasText: "can break sites" }).getByRole("button", { name: "Reset all (1)" })).toBeVisible();
	await expect(frame.locator("details, summary")).toHaveCount(0);
	const disclosure = frame.locator(".ui-link-row").filter({ hasText: "Internal Debug: 1" });
	await expect(disclosure).toHaveAttribute("aria-expanded", "false");
	await expect(frame.getByText("Debug thing")).toHaveCount(0);

	await disclosure.click();
	await expect(disclosure).toHaveAttribute("aria-expanded", "true");
	await expect(frame.getByText("Debug thing")).toBeVisible();
});

test("an extension's page is built from the settings lists and names the extension once", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "extensionsChanged",
		ids: ["ext-a"],
		extensions: [{
			id: "ext-a", name: "Dark Reader: dark mode for every website", version: "4.9", description: "Dark mode for every website.", isEnabled: true,
			hasPopup: true, hasBackground: true, hasContentScripts: true, siteAccess: ["github.com"],
		}],
	}));
	await page.locator(".section-nav-button").filter({ hasText: "Extensions" }).click();
	await page.getByRole("button", { name: "Show details for Dark Reader: dark mode for every website" }).click();

	const frame = page.locator(".ui-shell-frame");
	const title = frame.locator(".ui-shell-frame-title");
	await expect(title).toHaveText("Dark Reader: dark mode for every website");
	await expect(frame.locator(".ui-shell-frame-main").getByText("Dark Reader: dark mode for every website", { exact: true })).toHaveCount(0);
	// The header is the only place naming it: a narrow window wraps the name rather than cutting it.
	await page.setViewportSize({ width: 600, height: 400 });
	expect(await title.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
	await expect(frame.locator(".detail-description")).toHaveText("Dark mode for every website.");
	await expect(frame.locator(".detail-head .detail-chip")).toHaveText(["Action popup", "Background page", "Content scripts"]);
	await expect(frame.locator(".ui-inset-list-title")).toContainText(["Site access"]);
	await expect(frame.locator(".ui-list-row").filter({ hasText: "Enabled" }).getByRole("checkbox")).toBeChecked();
	await expect(frame.getByRole("textbox", { name: "Site access" })).toHaveClass(/ui-text-field/);
	await expect(frame.getByRole("button", { name: "Add" })).toHaveClass(/ui-button/);
	await expect(frame.getByRole("button", { name: "Remove Extension..." })).toBeVisible();

	await frame.getByRole("textbox", { name: "Site access" }).fill("docs.example.com");
	await frame.getByRole("button", { name: "Add" }).click();
	const sent = (await sentCommands(page)).filter((command) => command.action === "setExtensionSiteAccess");
	expect(sent.at(-1)?.payload).toMatchObject({ id: "ext-a", hosts: ["github.com", "docs.example.com"] });
});

test("a Space whose tabs the chrome has not loaded yet shows no tab count", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: "Tabs and spaces" }).click();

	const row = (name: string) => page.locator(".ui-list-row").filter({ has: page.locator(".ui-list-row-title", { hasText: name }) });
	await expect(row("Work")).toContainText("Tabs: 5");
	// Play holds a tab, but only the active Space's tabs come with the initial state.
	await expect(row("Play")).not.toContainText("Tabs:");
});

test.describe("in French at the window's minimum size", () => {
	test.use({ locale: "fr-FR", viewport: { width: 600, height: 400 } });

	test("a row's control never covers its label", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		await page.evaluate(() => window.__lilo!.receive({
			event: "settingsLoaded",
			settings: {
				downloadsFolder: "/Users/me/Documents/Téléchargements très importants du projet",
				agentControlEnabled: "true",
				agentAlwaysAllowedSites: JSON.stringify(["github.com", "docs.google.com"]),
				terminalLidClosed: "true",
			},
		}));

		for (const section of ["Général", "Onglets et Espaces", "Confidentialité", "Terminal", "Agents", "Avancé"]) {
			await page.locator(".section-nav-button").filter({ hasText: section }).click();
			const rows = page.locator(".ui-shell-frame .ui-list-row:has(.ui-list-row-action)");
			await expect(rows.first()).toBeVisible();
			for (const row of await rows.all()) {
				const title = row.locator(".ui-list-row-title");
				const copy = (await row.locator(".ui-list-row-copy").boundingBox())!;
				const action = (await row.locator(".ui-list-row-action").boundingBox())!;
				const controls = await row.locator(".ui-list-row-action > *").evaluateAll((els) => Math.max(...els.map((el) => el.getBoundingClientRect().right)));
				const box = (await row.boundingBox())!;
				const label = await title.textContent();
				const overlaps = copy.x + copy.width > action.x && action.y < copy.y + copy.height && copy.y < action.y + action.height;
				expect(overlaps, `${section}: "${label}"`).toBe(false);
				expect(controls, `${section}: "${label}"`).toBeLessThanOrEqual(box.x + box.width + 1);
				expect(await title.evaluate((el) => el.scrollWidth <= el.clientWidth), `${section}: "${label}"`).toBe(true);
			}
		}
	});

	test("a link rule shows its whole match, pattern and destination", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		await page.evaluate(() => window.__lilo!.receive({
			event: "settingsLoaded",
			settings: { externalLinkRules: JSON.stringify([{ match: "contains", pattern: "github.com", destination: "space-1" }]) },
		}));

		const rule = page.locator('[data-rule-index="0"]');
		await expect(rule).toBeVisible();
		await expectFieldsShowTheirText(rule.locator("select, input"));
	});

	test("a search engine's fields show their whole value", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		await page.locator(".ui-link-row").filter({ hasText: "Moteurs de recherche" }).click();

		const fields = page.locator(".engine-row").nth(1).locator("input");
		await expect(fields.first()).toBeVisible();
		await expectFieldsShowTheirText(fields.first());
	});
});

test("a feature flag known only by its key keeps the key inside its row", async ({ page }) => {
	await page.setViewportSize({ width: 600, height: 400 });
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	const key = "ExperimentalSiteIsolationForCrossOriginFramesEnabled";
	await page.evaluate((flagKey) => window.__lilo!.receive({
		event: "featureFlagsLoaded",
		flags: [{ key: flagKey, name: "", details: "", kind: "experimental", enabled: false, modified: false }],
	}), key);
	await page.locator(".section-nav-button").filter({ hasText: "Advanced" }).click();

	const title = page.locator(".ui-list-row-title").filter({ hasText: key });
	await expect(title).toBeVisible();
	expect(await title.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
});

test.describe("in Spanish", () => {
	test.use({ locale: "es-MX", viewport: { width: 600, height: 400 } });

	test("a regional system language selects Spanish and the selector persists a new choice", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));

		const language = page.getByRole("combobox", { name: "Idioma", exact: true });
		await expect(language).toHaveValue("es");
		await expect(language.locator("option:checked")).toHaveText("Español");
		await expect(page.getByRole("button", { name: "Pestañas y Espacios", exact: true })).toBeVisible();

		await language.selectOption("en");
		await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
		expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "en")).toBe(true);

		await page.getByRole("combobox", { name: "Language", exact: true }).selectOption("es");
		await expect(page.getByRole("combobox", { name: "Idioma", exact: true })).toHaveValue("es");
		expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "es")).toBe(true);
	});
});

test.describe("in Simplified Chinese", () => {
	test.use({ locale: "zh-CN", viewport: { width: 600, height: 400 } });

	test("the regional system language selects Chinese and the selector persists changes", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));

		const language = page.getByRole("combobox", { name: "语言", exact: true });
		await expect(language).toHaveValue("zh-Hans");
		await expect(language.locator("option:checked")).toHaveText("简体中文");
		await expectFieldsShowTheirText(language);
		await expect(page.getByRole("button", { name: "标签页与空间", exact: true })).toBeVisible();

		await language.selectOption("en");
		await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
		expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "en")).toBe(true);

		await page.getByRole("combobox", { name: "Language", exact: true }).selectOption("zh-Hans");
		await expect(page.getByRole("combobox", { name: "语言", exact: true })).toHaveValue("zh-Hans");
		expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "zh-Hans")).toBe(true);
	});

	test("controls fit beside Chinese labels at the minimum window size", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		for (const section of ["通用", "外观", "标签页与空间", "隐私", "终端", "智能体", "高级"]) {
			await page.getByRole("button", { name: section, exact: true }).click();
			const rows = page.locator(".ui-shell-frame .ui-list-row:has(.ui-list-row-action)");
			await expect(rows.first()).toBeVisible();
			for (const row of await rows.all()) {
				const title = row.locator(".ui-list-row-title");
				const copy = (await row.locator(".ui-list-row-copy").boundingBox())!;
				const action = (await row.locator(".ui-list-row-action").boundingBox())!;
				const label = await title.textContent();
				const overlaps = copy.x + copy.width > action.x && action.y < copy.y + copy.height && copy.y < action.y + action.height;
				expect(overlaps, `${section}: "${label}"`).toBe(false);
				expect(await title.evaluate((el) => el.scrollWidth <= el.clientWidth), `${section}: "${label}"`).toBe(true);
			}
		}
	});
});

test("a saved Chinese choice overrides the system language when settings load", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "zh-Hans" } });
		window.__lilo!.receive({ event: "openSettings" });
	});
	await expect(page.getByRole("combobox", { name: "语言", exact: true })).toHaveValue("zh-Hans");
});

test.describe("in Russian", () => {
	test.use({ locale: "ru-RU", viewport: { width: 600, height: 400 } });

	test("the regional system language selects Russian and language changes persist", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));

		const language = page.getByRole("combobox", { name: "Язык", exact: true });
		await expect(language).toHaveValue("ru");
		await expect(language.locator("option:checked")).toHaveText("Русский");
		await expectFieldsShowTheirText(language);

		await language.selectOption("en");
		await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
		expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "en")).toBe(true);

		await page.getByRole("combobox", { name: "Language", exact: true }).selectOption("ru");
		await expect(page.getByRole("combobox", { name: "Язык", exact: true })).toHaveValue("ru");
		expect((await sentCommands(page)).some((command) => command.action === "setSetting" && command.payload.key === "locale" && command.payload.value === "ru")).toBe(true);
	});

	test("controls fit beside Russian labels at the minimum window size", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		for (const section of ["Основные", "Оформление", "Вкладки и пространства", "Аудио и видео", "Конфиденциальность", "Терминал", "Агенты", "Дополнительно"]) {
			await page.getByRole("button", { name: section, exact: true }).click();
			const rows = page.locator(".ui-shell-frame .ui-list-row:has(.ui-list-row-action)");
			await expect(rows.first()).toBeVisible();
			for (const row of await rows.all()) {
				const title = row.locator(".ui-list-row-title");
				const copy = (await row.locator(".ui-list-row-copy").boundingBox())!;
				const action = (await row.locator(".ui-list-row-action").boundingBox())!;
				const box = (await row.boundingBox())!;
				const controls = await row.locator(".ui-list-row-action > *").evaluateAll((els) => Math.max(...els.map((el) => el.getBoundingClientRect().right)));
				const label = await title.textContent();
				const overlaps = copy.x + copy.width > action.x && action.y < copy.y + copy.height && copy.y < action.y + action.height;
				expect(overlaps, `${section}: "${label}"`).toBe(false);
				expect(controls, `${section}: "${label}"`).toBeLessThanOrEqual(box.x + box.width + 1);
				expect(await title.evaluate((el) => el.scrollWidth <= el.clientWidth), `${section}: "${label}"`).toBe(true);
			}
		}
	});
});

test("a saved Russian choice overrides the system language when settings load", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		window.__lilo!.receive({ event: "settingsLoaded", settings: { locale: "ru" } });
		window.__lilo!.receive({ event: "openSettings" });
	});
	await expect(page.getByRole("combobox", { name: "Язык", exact: true })).toHaveValue("ru");
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("an extension update check agrees in number", async ({ page }) => {
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
		await page.locator(".section-nav-button").filter({ hasText: "Extensions" }).click();
		await page.evaluate(() => window.__lilo!.receive({
			event: "extensionsChanged",
			ids: [],
			extensions: [],
			updateCheck: { lastCheck: 1760000000, available: 1, failed: 2 },
		}));

		const row = page.locator('[data-setting-id="checkExtensionUpdates"]');
		await expect(row).toContainText("1 mise à jour disponible ·");
		await expect(row).toContainText("2 non vérifiées");
	});
});

for (const [locale, megabytes, percent, terminal] of [["en-US", "10 MB", "20%", "Terminal"], ["fr-FR", "10 Mo", "20 %", "Terminal"], ["ru-RU", "10 МБ", "20 %", "Терминал"]]) {
	test.describe(locale, () => {
		test.use({ locale });

		test(`the terminal's sizes read ${megabytes} and ${percent}`, async ({ page }) => {
			await bootChrome(page, initialWorld());
			await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
			await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { terminalLidClosed: "true" } }));
			await page.locator(".section-nav-button").filter({ hasText: terminal }).click();

			const texts = await page.locator(".ui-shell-frame select option").allTextContents();
			expect(texts.map((text) => text.replace(/\s/g, " ").trim())).toContain(megabytes);
			expect(texts.map((text) => text.replace(/\s/g, " ").trim())).toContain(percent);
		});
	});
}

/** Each field is wide enough for the text it shows, padding included. */
async function expectFieldsShowTheirText(fields: Locator): Promise<void> {
	for (const field of await fields.all()) {
		const [needed, width] = await field.evaluate((el) => {
			const control = el as HTMLInputElement | HTMLSelectElement;
			const text = control instanceof HTMLSelectElement ? control.selectedOptions[0].text : control.value;
			const style = getComputedStyle(control);
			const context = document.createElement("canvas").getContext("2d")!;
			context.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
			const padding = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight) + parseFloat(style.borderLeftWidth) * 2;
			return [context.measureText(text).width + padding, control.getBoundingClientRect().width];
		});
		// Canvas and native controls round fractional glyph widths differently.
		expect(needed, await field.getAttribute("aria-label") ?? "").toBeLessThanOrEqual(Math.ceil(width));
	}
}

test("a search result's highlight clears with Reduce motion on", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-toolbar input").fill("Theme");

	await page.locator(".search-hit").filter({ hasText: "Theme" }).first().click();

	const row = page.locator('[data-setting-id="theme"]');
	await expect(row).toHaveClass(/setting-flash/);
	await expect(row).not.toHaveClass(/setting-flash/, { timeout: 4000 });
});

test("connecting an agent app shows it working until Lilo answers", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { agentControlEnabled: "true" } }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "agentClientsLoaded",
		clients: [{ id: "claudeCode", configured: false, icon: null }],
		allowed: [],
	}));
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();

	const connect = page.locator(".agent-tile .ui-button.primary");
	await connect.click();
	await expect(connect).toHaveAttribute("aria-busy", "true");
	await expect(connect).toBeDisabled();
	await connect.click({ force: true });
	expect((await sentCommands(page)).filter((command) => command.action === "connectAgentClient")).toHaveLength(1);

	await page.evaluate(() => window.__lilo!.receive({ event: "settingsActionCompleted", action: "connectAgentClient", message: "Connected", level: "info" }));
	await expect(connect).toHaveAttribute("aria-busy", "false");
});

test("a settings group's heading is its small caps title alone and keeps its height in search results", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));

	const browser = page.locator(".ui-shell-frame").getByRole("region", { name: "Browser", exact: true });
	const heading = browser.getByRole("heading", { name: "Browser", exact: true });
	await expect(heading).toBeVisible();
	await expect(heading).toHaveCSS("text-transform", "uppercase");
	await expect(page.locator(".ui-shell-frame .ui-inset-list-icon")).toHaveCount(0);
	const titleHeight = () => page.locator(".ui-shell-frame .ui-inset-list-title").first().evaluate((el) => getComputedStyle(el).height);
	const inSection = await titleHeight();

	await page.getByRole("searchbox", { name: "Search settings" }).fill("download");
	await expect(page.locator(".ui-shell-frame .search-hit").first()).toBeVisible();
	expect(await titleHeight()).toBe(inSection);
});

test("the sleep modes write the switches' settings keys", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: "Terminal" }).click();

	const modes = page.getByRole("radiogroup", { name: "Keep the Mac awake during commands" });
	const lidGroup = page.getByRole("region", { name: "Lid closed", exact: true });
	const lastSettings = async (count: number) =>
		(await sentCommands(page)).filter((command) => command.action === "setSetting").slice(-count).map((command) => command.payload);
	await expect(modes.getByRole("radio", { name: "On" })).toBeChecked();
	await expect(lidGroup).toHaveCount(0);

	await modes.getByRole("radio", { name: "Lid closed too" }).click();
	expect(await lastSettings(2)).toEqual([{ key: "terminalPreventSleep", value: "true" }, { key: "terminalLidClosed", value: "true" }]);
	await expect(lidGroup).toBeVisible();
	await expect(lidGroup.locator(".ui-badge")).toHaveText("Not installed");

	// Off leaves the lid choice for next time, as turning the first switch off did.
	await modes.getByRole("radio", { name: "Off" }).click();
	expect(await lastSettings(1)).toEqual([{ key: "terminalPreventSleep", value: "false" }]);
	await expect(lidGroup).toHaveCount(0);
	await modes.getByRole("radio", { name: "Lid closed too" }).click();
	await expect(lidGroup).toBeVisible();

	await modes.getByRole("radio", { name: "On" }).click();
	expect(await lastSettings(2)).toEqual([{ key: "terminalPreventSleep", value: "true" }, { key: "terminalLidClosed", value: "false" }]);
	await expect(lidGroup).toHaveCount(0);
});

test("a build that cannot run the sleep helper offers no lid mode", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { terminalLidClosed: "true" } }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "keepAwakeChanged", helperStatus: "unsigned",
	}));
	await page.locator(".section-nav-button").filter({ hasText: "Terminal" }).click();

	const modes = page.getByRole("radiogroup", { name: "Keep the Mac awake during commands" });
	await expect(modes.getByRole("radio")).toHaveText(["Off", "On"]);
	await expect(modes.getByRole("radio", { name: "On" })).toBeChecked();
	await expect(page.getByRole("region", { name: "Lid closed", exact: true })).toHaveCount(0);
});

test("an always-allowed site's chip removes that site only", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "settingsLoaded",
		settings: { agentControlEnabled: "true", agentAlwaysAllowedSites: JSON.stringify(["github.com", "docs.google.com"]) },
	}));
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();

	const row = page.locator('[data-setting-id="agentAlwaysAllowed"]');
	await expect(row.locator(".ui-chip")).toHaveText(["github.com", "docs.google.com"]);
	await row.getByRole("button", { name: "Remove github.com" }).click();

	await expect(row.locator(".ui-chip")).toHaveText(["docs.google.com"]);
	const sent = (await sentCommands(page)).filter((command) => command.action === "setSetting");
	expect(sent.at(-1)?.payload).toEqual({ key: "agentAlwaysAllowedSites", value: JSON.stringify(["docs.google.com"]) });
});

test("each agent app shows its status line and at most one action", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { agentControlEnabled: "true" } }));
	const icon = "data:image/gif;base64,R0lGODlhAQABAAAAACw=";
	await page.evaluate((icon) => window.__lilo!.receive({
		event: "agentClientsLoaded",
		clients: [
			{ id: "claudeCode", configured: true, icon },
			{ id: "cursor", configured: true, icon: null },
			{ id: "codex", configured: false, icon },
			{ id: "claudeDesktop", configured: true, icon },
		],
		allowed: [{ name: "claude-code", displayName: "Claude Code", lastSeen: null, client: "claudeCode" }],
	}), icon);
	await page.evaluate(() => window.__lilo!.receive({
		event: "agentActivity", moods: {}, clients: [{ name: "claude-code", busy: false, actingTabIds: [], spaceIds: [] }], agentsSpaceIds: [], agentsProfileId: "", hiddenAgentsSpaceIds: [],
	}));
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();

	const row = (name: string) => page.locator(".agent-tile, [data-setting-id='agentOther']").filter({ has: page.locator(".name, .ui-list-row-title", { hasText: name }) });
	const expectRow = async (name: string, status: string | null, buttons: string[]) => {
		if (status) await expect(row(name).locator(".status")).toHaveText(status);
		await expect(row(name).getByRole("button")).toHaveText(buttons);
	};
	await expectRow("Claude Code", "Connected", ["Remove"]);
	await expectRow("Cursor", "Not installed", []);
	await expectRow("Codex", "Adds Lilo to its MCP servers.", ["Connect"]);
	await expectRow("Claude Desktop", "Configured. Lilo asks you the first time it connects.", []);
	await expectRow("Other agents", null, ["Copy Configuration"]);
	await expect(row("Claude Code")).toHaveAttribute("data-agent-status", "connected");

	await page.evaluate(() => window.__lilo!.receive({
		event: "agentActivity", moods: {}, clients: [{ name: "claude-code", busy: true, actingTabIds: [], spaceIds: [] }], agentsSpaceIds: [], agentsProfileId: "", hiddenAgentsSpaceIds: [],
	}));
	await expectRow("Claude Code", "Acting now", ["Remove"]);
	await page.evaluate(() => window.__lilo!.receive({ event: "agentActivity", moods: {}, clients: [], agentsSpaceIds: [], agentsProfileId: "", hiddenAgentsSpaceIds: [] }));
	await expectRow("Claude Code", "Allowed", ["Remove"]);

	await row("Claude Code").getByRole("button", { name: "Remove" }).click();
	const revoked = (await sentCommands(page)).filter((command) => command.action === "revokeAgentClient");
	expect(revoked.map((command) => command.payload)).toEqual([{ name: "claude-code" }]);
});

test("content blocking nests what it blocks under its switch, then its lists", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "settingsLoaded", settings: { contentBlockerAllowlist: JSON.stringify(["lemonde.fr", "bbc.co.uk"]) },
	}));
	await page.locator(".section-nav-button").filter({ hasText: "Privacy" }).click();

	const frame = page.locator(".ui-shell-frame");
	const titles = frame.locator(".ui-inset-list-title");
	await expect(titles).toContainText(["Content blocking", "Lists and exceptions", "Site permissions"]);
	await expect(frame.getByRole("region", { name: "Content blocking" }).locator('[data-setting-id="blockerTrackers"]')).toBeVisible();
	const sites = frame.locator('[data-setting-id="blockerSites"] .ui-link-row');
	await expect(sites.locator(".ui-link-row-count")).toHaveText("2");
	await expect(sites).not.toContainText("lemonde.fr");

	await frame.locator('[data-setting-id="contentBlocker"]').locator(".ui-toggle").click();
	await expect(frame.locator('[data-setting-id="blockerTrackers"]')).toHaveCount(0);
	await expect(frame.locator('[data-setting-id="blockerSites"]')).toHaveCount(0);
});

test("seven clicks on the version row unlock Lilo's developer tools, once", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	const row = page.locator(".ui-list-row").filter({ has: page.getByRole("button", { name: "Check now" }) }).first();

	for (let click = 0; click < 6; click++) await row.locator(".ui-list-row-title").click();
	expect((await sentCommands(page)).filter((c) => c.action === "unlockDeveloperTools")).toHaveLength(0);
	await row.locator(".ui-list-row-title").click();
	await row.locator(".ui-list-row-title").click();

	expect((await sentCommands(page)).filter((c) => c.action === "unlockDeveloperTools")).toHaveLength(1);
	await expect(row).toContainText("developer tools are now in the Develop menu");
	const button = (await row.getByRole("button", { name: "Check now" }).boundingBox())!;
	expect(button.x, "the button sits beside the text, as on every row").toBeGreaterThan((await row.locator(".ui-list-row-title").boundingBox())!.x + 100);
});
