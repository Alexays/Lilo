import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("shells and panels are mutually exclusive surfaces with per-shell sections", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const panels = await loadStore("/src/stores/panels.svelte.ts");

	panels.openSettings();
	assert.equal(panels.isSettingsShellOpen(), true);
	assert.equal(panels.getSettingsShellSection(), "general");

	panels.setActiveSettingsSection("privacy");
	assert.equal(panels.getSettingsShellSection(), "privacy");

	// Opening another shell closes the current one.
	panels.openDesignSystem();
	assert.equal(panels.isSettingsShellOpen(), false);
	assert.equal(panels.isDesignSystemShellOpen(), true);
	assert.equal(panels.getDesignSystemShellSection(), "foundations");

	// Sections are tracked per shell.
	panels.setActiveDesignSystemSection("controls");
	assert.equal(panels.getSettingsShellSection(), "privacy");
	assert.equal(panels.getDesignSystemShellSection(), "controls");

	// Downloads is a system screen of its own.
	panels.openDownloadsPanel();
	assert.equal(panels.isDesignSystemShellOpen(), false);
	assert.equal(panels.getPageShell(), "downloads");

	// Opening a panel closes any shell, and vice versa.
	panels.openAddEditor();
	assert.equal(panels.getPageShell(), null);
	assert.equal(panels.getActivePanel(), "editor");

	panels.openSettings("advanced");
	assert.equal(panels.getActivePanel(), null);
	assert.equal(panels.getSettingsShellSection(), "advanced");

	// Reopening a shell lands back on its default section.
	panels.openSettings();
	assert.equal(panels.getSettingsShellSection(), "general");
});

test("settings drill-in pages and search reset on section changes and reopen", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const panels = await loadStore("/src/stores/panels.svelte.ts");

	panels.openSettingsSubpage("sites", "site:example.com");
	assert.equal(panels.getSettingsShellSection(), "sites");
	assert.equal(panels.getSettingsSubpage(), "site:example.com");

	panels.setSettingsQuery("zoom");
	panels.setActiveSettingsSection("privacy");
	assert.equal(panels.getSettingsSubpage(), null);
	assert.equal(panels.getSettingsQuery(), "");

	panels.openSettingsSubpage("general", "engines");
	panels.closeSettingsShell();
	panels.openSettings();
	assert.equal(panels.getSettingsSubpage(), null);
});

test("a link opened from another app closes the shell covering the page", async () => {
	stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const panels = await loadStore("/src/stores/panels.svelte.ts");
	const commandBar = await loadStore("/src/stores/commandBar.svelte.ts");
	commandBar.initCommandBarStore();
	const { receive } = (globalThis as { window: { __lilo: { receive(msg: Record<string, unknown>): void } } }).window.__lilo;

	panels.openSettings();
	receive({ event: "closeCommandBarAfterNavigation" });
	assert.equal(panels.isSettingsShellOpen(), false);

	panels.openDesignSystem();
	receive({ event: "closeCommandBarAfterNavigation" });
	assert.equal(panels.isDesignSystemShellOpen(), false);
});

test("the page shell's open state is reported to native once per change", async () => {
	const posted = stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const panels = await loadStore("/src/stores/panels.svelte.ts");
	panels.initPanelsStore();
	const shellReports = () => posted.filter((m) => m.action === "pageShellChanged");

	panels.reportPageShellState();
	assert.equal(shellReports().length, 0, "no shell open, nothing to report");

	panels.openSettings();
	panels.reportPageShellState();
	panels.reportPageShellState();
	assert.deepEqual(shellReports(), [{ action: "pageShellChanged", payload: { open: true } }]);

	// Another shell keeps the state open: no new report.
	panels.openDownloadsPanel();
	panels.reportPageShellState();
	assert.equal(shellReports().length, 1);

	// The design system showcase is not a page shell.
	panels.openDesignSystem();
	panels.reportPageShellState();
	assert.deepEqual(shellReports().at(-1), { action: "pageShellChanged", payload: { open: false } });

	panels.openHistoryShell();
	panels.reportPageShellState();
	assert.equal(shellReports().at(-1)?.payload.open, true);

	// Native's ⌘W asks the chrome to close the screen.
	const { receive } = (globalThis as { window: { __lilo: { receive(msg: Record<string, unknown>): void } } }).window.__lilo;
	receive({ event: "closePageShell" });
	assert.equal(panels.getPageShell(), null);
	panels.reportPageShellState();
	assert.deepEqual(shellReports().at(-1), { action: "pageShellChanged", payload: { open: false } });
	assert.equal(shellReports().length, 4);
});

test("openExtensions lands on the named extension's details page", async () => {
	stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const panels = await loadStore("/src/stores/panels.svelte.ts");
	panels.initPanelsStore();
	const { receive } = (globalThis as { window: { __lilo: { receive(msg: Record<string, unknown>): void } } }).window.__lilo;

	receive({ event: "openExtensions", id: "abcdefghijklmnop" });
	assert.equal(panels.getSettingsShellSection(), "extensions");
	assert.equal(panels.getSettingsSubpage(), "extension:abcdefghijklmnop");

	receive({ event: "openExtensions" });
	assert.equal(panels.getSettingsShellSection(), "extensions");
	assert.equal(panels.getSettingsSubpage(), null);
});
