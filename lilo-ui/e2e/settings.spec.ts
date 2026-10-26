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
	await expect(reset).toHaveText("Reset all");
	expect(await reset.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
});

test("the agent rows line up and style their secondary buttons alike", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { agentControlEnabled: "true" } }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "agentClientsLoaded",
		clients: [{ id: "claudeCode", configured: true, icon: null }],
		allowed: [{ name: "claude-code", displayName: "Claude Code", lastSeen: null, client: "claudeCode" }],
	}));
	await page.locator(".section-nav-button").filter({ hasText: "AI agents" }).click();

	const titles = page.locator(".ui-shell-frame .agent-row .ui-list-row-title, .ui-shell-frame [data-setting-id='agentOther'] .ui-list-row-title");
	await expect(titles).toHaveCount(2);
	const [claude, other] = await titles.evaluateAll((els) => els.map((el) => el.getBoundingClientRect().left));
	expect(claude).toBe(other);

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
	const ruleRadii = [await fieldRadius('[data-rule-index="0"] select'), await fieldRadius('[data-rule-index="0"] input')];

	await page.locator(".ui-link-row").filter({ hasText: "Search engines" }).click();
	await expect(page.locator(".engine-row").first()).toBeVisible();
	expect(await look(".engine-row .engine-actions > .ui-button:last-child")).toEqual(ruleAction);
	expect(new Set(ruleRadii).size).toBe(1);
	expect(await fieldRadius(".engine-row input")).toBe(ruleRadii[0]);

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
	await expect(frame.locator(".ui-inset-list-title")).toContainText(["Description", "Capabilities", "Site access"]);
	await expect(frame.locator(".ui-list-row").filter({ hasText: "Enabled" }).getByRole("checkbox")).toBeChecked();
	await expect(frame.getByRole("textbox", { name: "Site access" })).toHaveClass(/ui-text-field/);
	await expect(frame.getByRole("button", { name: "Add" })).toHaveClass(/ui-button/);
	await expect(frame.locator(".ui-button.danger")).toHaveCount(1);

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

		for (const section of ["Général", "Onglets et espaces", "Confidentialité", "Terminal", "Agents IA", "Avancé"]) {
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

for (const [locale, megabytes, percent] of [["en-US", "10 MB", "20%"], ["fr-FR", "10 Mo", "20 %"]]) {
	test.describe(locale, () => {
		test.use({ locale });

		test(`the terminal's sizes read ${megabytes} and ${percent}`, async ({ page }) => {
			await bootChrome(page, initialWorld());
			await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
			await page.evaluate(() => window.__lilo!.receive({ event: "settingsLoaded", settings: { terminalLidClosed: "true" } }));
			await page.locator(".section-nav-button").filter({ hasText: "Terminal" }).click();

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
		expect(needed, await field.getAttribute("aria-label") ?? "").toBeLessThanOrEqual(width);
	}
}

test("a search result's highlight clears with Reduce motion on", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-toolbar input").fill("Theme");

	await page.locator(".ui-link-row").filter({ hasText: "Theme" }).first().click();

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
	await page.locator(".section-nav-button").filter({ hasText: "AI agents" }).click();

	const connect = page.locator(".agent-row .ui-button.primary");
	await connect.click();
	await expect(connect).toHaveAttribute("aria-busy", "true");
	await expect(connect).toBeDisabled();
	await connect.click({ force: true });
	expect((await sentCommands(page)).filter((command) => command.action === "connectAgentClient")).toHaveLength(1);

	await page.evaluate(() => window.__lilo!.receive({ event: "settingsActionCompleted", action: "connectAgentClient", message: "Connected", level: "info" }));
	await expect(connect).toHaveAttribute("aria-busy", "false");
});

test("a settings group's heading shows a decorative tile and keeps its height", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));

	const browser = page.locator(".ui-shell-frame").getByRole("region", { name: "Browser", exact: true });
	const icon = browser.locator(".ui-inset-list-title > .ui-inset-list-icon");
	await expect(icon).toHaveAttribute("aria-hidden", "true");
	await expect(icon.locator(".settings-group-icon svg")).toBeVisible();
	await expect(browser.getByRole("heading", { name: "Browser", exact: true })).toBeVisible();
	const titleHeight = () => page.locator(".ui-shell-frame .ui-inset-list-title").first().evaluate((el) => getComputedStyle(el).height);
	const withIcon = await titleHeight();

	// Search results are titled by section, without a tile.
	await page.getByRole("searchbox", { name: "Search settings" }).fill("download");
	await expect(page.locator(".ui-shell-frame .ui-inset-list-icon")).toHaveCount(0);
	expect(await titleHeight()).toBe(withIcon);
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
		event: "keepAwakeChanged", keepsAwake: false, agents: [], tabIds: [], holdsLidClosed: false, helperStatus: "unsigned",
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
	await page.locator(".section-nav-button").filter({ hasText: "AI agents" }).click();

	const row = page.locator('[data-setting-id="agentAlwaysAllowed"]');
	await expect(row.locator(".ui-chip")).toHaveText(["github.com", "docs.google.com"]);
	await row.getByRole("button", { name: "Remove github.com" }).click();

	await expect(row.locator(".ui-chip")).toHaveText(["docs.google.com"]);
	const sent = (await sentCommands(page)).filter((command) => command.action === "setSetting");
	expect(sent.at(-1)?.payload).toEqual({ key: "agentAlwaysAllowedSites", value: JSON.stringify(["docs.google.com"]) });
});

test("each agent app shows its status as a badge and at most one action", async ({ page }) => {
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
		event: "agentActivity", clients: [{ name: "claude-code", busy: false, actingTabIds: [] }], agentsSpaceId: "", agentsProfileId: "", agentsSpaceVisible: true,
	}));
	await page.locator(".section-nav-button").filter({ hasText: "AI agents" }).click();

	const row = (name: string) => page.locator(".agent-row").filter({ has: page.locator(".ui-list-row-title", { hasText: name }) });
	const expectRow = async (name: string, badge: string | null, buttons: string[]) => {
		await expect(row(name).locator(".ui-badge")).toHaveText(badge ? [badge] : []);
		await expect(row(name).getByRole("button")).toHaveText(buttons);
	};
	await expectRow("Claude Code", "Connected", ["Remove"]);
	await expectRow("Cursor", "Not installed", []);
	await expectRow("Codex", null, ["Connect"]);
	await expectRow("Claude Desktop", "Configured", []);
	await expectRow("Other agents", null, ["Copy configuration"]);
	await expect(row("Claude Code").locator(".ui-badge")).toHaveClass(/success/);

	await page.evaluate(() => window.__lilo!.receive({
		event: "agentActivity", clients: [{ name: "claude-code", busy: true, actingTabIds: [] }], agentsSpaceId: "", agentsProfileId: "", agentsSpaceVisible: true,
	}));
	await expectRow("Claude Code", "Acting now", ["Remove"]);
	await page.evaluate(() => window.__lilo!.receive({ event: "agentActivity", clients: [], agentsSpaceId: "", agentsProfileId: "", agentsSpaceVisible: true }));
	await expectRow("Claude Code", "Allowed", ["Remove"]);

	await row("Claude Code").getByRole("button", { name: "Remove" }).click();
	const revoked = (await sentCommands(page)).filter((command) => command.action === "revokeAgentClient");
	expect(revoked.map((command) => command.payload)).toEqual([{ name: "claude-code" }]);
});

test("content blocking splits into its switch, what it blocks, and its lists", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.evaluate(() => window.__lilo!.receive({
		event: "settingsLoaded", settings: { contentBlockerAllowlist: JSON.stringify(["lemonde.fr", "bbc.co.uk"]) },
	}));
	await page.locator(".section-nav-button").filter({ hasText: "Privacy" }).click();

	const frame = page.locator(".ui-shell-frame");
	const titles = frame.locator(".ui-inset-list-title");
	await expect(titles).toContainText(["Content blocking", "What Lilo blocks", "Lists and exceptions", "Site permissions"]);
	const sites = frame.locator('[data-setting-id="blockerSites"] .ui-link-row');
	await expect(sites.locator(".ui-link-row-count")).toHaveText("2");
	await expect(sites).not.toContainText("lemonde.fr");

	await frame.locator('[data-setting-id="contentBlocker"]').locator(".ui-toggle").click();
	await expect(frame.getByRole("region", { name: "What Lilo blocks" })).toHaveCount(0);
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
