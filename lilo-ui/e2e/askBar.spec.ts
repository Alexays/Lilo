import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("picking an agent from the ask bar's menu selects it and keeps the bar open", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		const lilo = window.__lilo!;
		lilo.receive({ event: "settingsLoaded", settings: { agentsEnabled: "true" } });
		lilo.receive({ event: "openAskBar", selection: "" });
		lilo.receive({
			event: "agentCatalog",
			agents: [
				{ id: "claude-acp", name: "Claude Agent", description: "" },
				{ id: "codex-acp", name: "Codex", description: "" },
			],
			projects: [],
			home: "/Users/example",
		});
	});
	const bar = page.locator(".ask-bar");
	const picker = bar.getByRole("button", { name: "Agent", exact: true });
	await picker.click();
	await page.getByRole("menuitemradio", { name: "Codex" }).click();

	await expect(bar).toBeVisible();
	await expect(picker).toContainText("Codex");
});
