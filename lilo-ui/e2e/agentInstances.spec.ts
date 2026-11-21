import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const INSTANCES = JSON.stringify([
	{ id: "codex-acp", source: "registry", registryId: "codex-acp", name: "Codex", enabled: true },
	{ id: "command-abc", source: "command", name: "Mine", executable: "/usr/local/bin/mine-agent", arguments: "--profile\nacp", enabled: false },
]);

// A small made-up registry: the featured pair, one to find by searching, and the user's own command
// echoed back as the host sends it (kept out of the registry search results).
const agents = [
	{ id: "codex-acp", name: "Codex", description: "A made-up coding agent", featured: true, repository: "https://github.com/example/codex-acp", license: "Apache-2.0" },
	{ id: "gemini", name: "Gemini CLI", description: "Another made-up agent", featured: true, repository: "https://github.com/example/gemini", license: "Apache-2.0" },
	{ id: "auggie", name: "Auggie CLI", description: "A third made-up agent", repository: "https://github.com/example/auggie", license: "MIT" },
	{ id: "command-abc", name: "Mine", description: "/usr/local/bin/mine-agent", featured: true, command: true },
];

async function openAgentsPage(page: Page): Promise<void> {
	const world = initialWorld();
	world.settings = { agentsEnabled: "true", agentAcpInstances: INSTANCES };
	await bootChrome(page, world);
	await page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, [
		{ event: "openSettings" },
		{ event: "agentCatalog", agents, projects: [], home: "/Users/example" },
	]);
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();
	await page.locator("[data-setting-id='agentInstances'] .ui-link-row").click();
}

async function lastInstanceWrite(page: Page): Promise<unknown[]> {
	const writes = (await sentCommands(page)).filter(
		(command) => command.action === "setSetting" && command.payload.key === "agentAcpInstances",
	);
	return JSON.parse(writes.at(-1)!.payload.value as string) as unknown[];
}

test("the ask bar picker hides a disabled agent", async ({ page }) => {
	const world = initialWorld();
	world.settings = {
		agentsEnabled: "true",
		agentAcpInstances: JSON.stringify([{ id: "gemini", source: "registry", registryId: "gemini", enabled: false }]),
	};
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

test("the agents list shows each entry with a toggle that writes the setting", async ({ page }) => {
	await openAgentsPage(page);

	const rows = page.locator(".settings-section-content .ui-list-row");
	await expect(rows).toHaveCount(2);
	await expect(rows.first()).toContainText("Codex");
	await expect(rows.first()).toContainText("Registry");
	await expect(rows.last()).toContainText("Mine");
	await expect(rows.last()).toContainText("/usr/local/bin/mine-agent");

	const toggle = rows.last().getByRole("checkbox");
	await expect(toggle).not.toBeChecked();
	// The input is the label's invisible hit area; the track the user sees toggles it.
	await rows.last().locator(".ui-toggle").click();
	await expect(toggle).toBeChecked();
	await expect.poll(() => lastInstanceWrite(page)).toEqual(
		expect.arrayContaining([expect.objectContaining({ id: "command-abc", enabled: true })]),
	);
});

test("the add sheet searches the registry, shows repository and license, and adds", async ({ page }) => {
	await openAgentsPage(page);
	await page.getByRole("button", { name: "Add Agent" }).click();

	const sheet = page.locator(".ui-modal-panel");
	await expect(sheet).toBeVisible();
	// Already in the list, the featured agent offers no second entry; the user's command stays out of the search.
	await expect(sheet.locator(".result")).toHaveCount(3);
	await expect(sheet.locator(".result").filter({ hasText: "Codex" }).getByRole("button")).toBeDisabled();
	await expect(sheet.locator(".result").filter({ hasText: "Mine" })).toHaveCount(0);

	const auggie = sheet.locator(".result").filter({ hasText: "Auggie CLI" });
	await expect(auggie.locator(".meta")).toHaveText("github.com/example/auggie · MIT");

	await sheet.getByRole("searchbox").fill("aug");
	await expect(sheet.locator(".result")).toHaveCount(1);

	await auggie.getByRole("button", { name: "Add" }).click();
	await expect(sheet).toBeHidden();
	await expect.poll(() => lastInstanceWrite(page)).toEqual(
		expect.arrayContaining([expect.objectContaining({ id: "auggie", source: "registry", registryId: "auggie", enabled: true })]),
	);
});

test("the command tab adds an entry, and the row's menu edits and removes it", async ({ page }) => {
	await openAgentsPage(page);
	await page.getByRole("button", { name: "Add Agent" }).click();
	const sheet = page.locator(".ui-modal-panel");
	await sheet.getByRole("radio", { name: "Custom Command" }).click();

	const fields = sheet.locator(".command input");
	await fields.nth(0).fill("Example Agent");
	await fields.nth(1).fill("/opt/example/bin/example-acp");
	// The field commits on blur, like the real keyboard flow.
	await fields.nth(1).blur();
	await sheet.getByRole("button", { name: "Add", exact: true }).click();
	await expect(sheet).toBeHidden();

	const writes = await lastInstanceWrite(page);
	const added = writes.find((entry) => (entry as { executable?: string }).executable === "/opt/example/bin/example-acp") as { id: string; name: string };
	expect(added.name).toBe("Example Agent");

	const row = page.locator(".settings-section-content .ui-list-row").filter({ hasText: "Example Agent" });
	await expect(row).toHaveCount(1);

	await row.getByRole("button", { name: "Actions for Example Agent" }).click();
	await page.getByRole("menuitem", { name: "Edit" }).click();
	await expect(sheet.locator(".command input").nth(1)).toHaveValue("/opt/example/bin/example-acp");
	await sheet.getByRole("button", { name: "Cancel" }).click();

	await row.getByRole("button", { name: "Actions for Example Agent" }).click();
	await page.getByRole("menuitem", { name: "Remove" }).click();
	await expect(page.locator(".settings-section-content .ui-list-row").filter({ hasText: "Example Agent" })).toHaveCount(0);
});
