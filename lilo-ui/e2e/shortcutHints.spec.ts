import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, LILO_SHORTCUT_KEYS } from "./fixtures";

// The Arc preset's keys for the actions it moves.
const ARC_SHORTCUT_KEYS = { ...LILO_SHORTCUT_KEYS, "sidebar.toggle": "⌘S", "page.save": "⇧⌘S", "downloads.show": "⇧⌘J" };

test("command bar rows name the keys the user's bindings give each action", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), shortcutKeys: ARC_SHORTCUT_KEYS });
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	const helper = page.locator(".command-bar-result.selected .result-helper");

	await input.fill(":toggle sidebar");
	await expect(helper).toHaveText("⌘S");
	await input.fill(":save page");
	await expect(helper).toHaveText("⇧⌘S");

	// A binding changed in Settings shows at once.
	await page.evaluate(() => window.__lilo!.receive({ event: "shortcutKeys", keys: { "page.save": "⌥⌘S" } }));
	await input.fill(":save page as");
	await expect(helper).toHaveText("⌥⌘S");
});

test("an action left unbound shows no keys in the command bar", async ({ page }) => {
	const { "tab.reopenClosed": _unbound, ...keys } = LILO_SHORTCUT_KEYS;
	await bootChrome(page, { ...initialWorld(), shortcutKeys: keys });
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));

	await page.locator(".command-bar-input").fill(":reopen closed");

	await expect(page.locator(".command-bar-result.selected")).toContainText("Reopen");
	await expect(page.locator(".command-bar-result.selected .result-helper")).toHaveCount(0);
});

test("the sidebar's toolbar buttons name their action and its keys", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), shortcutKeys: ARC_SHORTCUT_KEYS });
	const tip = page.locator(".lilo-tooltip");

	await page.getByRole("button", { name: "Collapse sidebar" }).hover();
	await expect(tip).toContainText("Collapse sidebar");
	await expect(tip.locator(".lilo-tooltip-shortcut")).toHaveText("⌘S");

	await page.getByRole("button", { name: "Reload" }).hover();
	await expect(tip).toContainText("Reload");
	await expect(tip.locator(".lilo-tooltip-shortcut")).toHaveText("⌘R");
});

test("the Space tiles' tooltips follow the Space shortcuts", async ({ page }) => {
	await bootChrome(page, { ...initialWorld(), shortcutKeys: { ...LILO_SHORTCUT_KEYS, "space.select2": "⌥2" } });

	await page.locator(".space-icon-btn", { hasText: "P" }).hover();

	await expect(page.locator(".lilo-tooltip .lilo-tooltip-shortcut")).toHaveText("⌥2");
});
