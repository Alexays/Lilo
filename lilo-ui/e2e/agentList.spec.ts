import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const COMMANDS = JSON.stringify([{ id: "command-abc", name: "Mine", executable: "/usr/local/bin/mine-agent", arguments: "--profile\nacp", environment: "" }]);

// A small made-up catalog: two featured registry agents, one more, and the user's command as the host echoes it.
const agents = [
	{ id: "codex-acp", name: "Codex", description: "A made-up coding agent", featured: true },
	{ id: "gemini", name: "Gemini CLI", description: "Another made-up agent", featured: true },
	{ id: "auggie", name: "Auggie CLI", description: "A third made-up agent" },
	{ id: "command-abc", name: "Mine", description: "/usr/local/bin/mine-agent", featured: true, command: true },
];

async function openAgentList(page: Page, settings: Record<string, string>): Promise<void> {
	const world = initialWorld();
	world.settings = { agentsEnabled: "true", agentCommands: COMMANDS, ...settings };
	await bootChrome(page, world);
	await page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, [
		{ event: "openSettings" },
		{ event: "agentCatalog", agents, projects: [], home: "/Users/example" },
	]);
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();
	await page.locator("[data-setting-id='agentList'] .ui-link-row").click();
}

async function lastWrite(page: Page, key: string): Promise<unknown> {
	const writes = (await sentCommands(page)).filter((command) => command.action === "setSetting" && command.payload.key === key);
	return JSON.parse(writes.at(-1)!.payload.value as string);
}

test("the ask bar picker leaves out a hidden agent", async ({ page }) => {
	const world = initialWorld();
	world.settings = { agentsEnabled: "true", agentsHidden: JSON.stringify(["gemini"]) };
	await bootChrome(page, world);
	await page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, [
		{ event: "openAskBar", selection: "" },
		{ event: "agentCatalog", agents, projects: ["/Users/example/Code/acme"], home: "/Users/example" },
	]);
	await page.locator(".ask-bar").getByRole("button", { name: "Agent", exact: true }).click();
	const options = page.getByRole("menuitemradio");
	await expect(options).toHaveCount(3);
	await expect(options.filter({ hasText: "Gemini" })).toHaveCount(0);
});

test("every agent has a switch, and turning one off keeps the other hidden ids", async ({ page }) => {
	await openAgentList(page, { agentsHidden: JSON.stringify(["gone-from-this-profile", "command-abc"]) });

	const rows = page.locator(".settings-section-content .ui-list-row");
	await expect(rows).toHaveCount(4);
	await expect(rows.first()).toContainText("Mine");
	await expect(rows.first()).toContainText("/usr/local/bin/mine-agent --profile acp");
	await expect(rows.first().getByRole("checkbox")).not.toBeChecked();

	const gemini = rows.filter({ hasText: "Gemini CLI" });
	await expect(gemini.getByRole("checkbox")).toBeChecked();
	// The input is the label's invisible hit area; the track the user sees toggles it.
	await gemini.locator(".ui-toggle").click();
	await expect.poll(() => lastWrite(page, "agentsHidden")).toEqual(["gone-from-this-profile", "command-abc", "gemini"]);
});

test("a command is added as it is typed, then edited and removed from its menu", async ({ page }) => {
	await openAgentList(page, {});
	await page.getByRole("button", { name: "Add Command" }).click();
	const sheet = page.locator(".ui-modal-panel");
	const fields = sheet.locator("input");
	await fields.nth(0).fill("Example Agent");
	await fields.nth(1).fill("/opt/example/bin/example-acp");
	// Still in the field: the Add button follows what is typed.
	await sheet.getByRole("button", { name: "Add", exact: true }).click();
	await expect(sheet).toBeHidden();

	const added = ((await lastWrite(page, "agentCommands")) as { id: string; name: string; executable: string }[]).at(-1)!;
	expect(added).toMatchObject({ name: "Example Agent", executable: "/opt/example/bin/example-acp" });
	expect(added.id).toMatch(/^command-/);

	const row = page.locator(".settings-section-content .ui-list-row").filter({ hasText: "Example Agent" });
	await row.getByRole("button", { name: "Actions for Example Agent" }).click();
	await page.getByRole("menuitem", { name: "Edit" }).click();
	await expect(sheet.locator("input").nth(1)).toHaveValue("/opt/example/bin/example-acp");
	await sheet.getByRole("button", { name: "Cancel" }).click();

	await row.getByRole("button", { name: "Actions for Example Agent" }).click();
	await page.getByRole("menuitem", { name: "Remove" }).click();
	await expect(row).toHaveCount(0);
	expect(await lastWrite(page, "agentCommands")).toEqual([expect.objectContaining({ id: "command-abc" })]);
});
