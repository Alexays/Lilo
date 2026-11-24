import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";
import { tab } from "../src/stores/testFixtures";

const models = [
	{ id: "fast-1", name: "Fast One", description: "Small and quick" },
	{ id: "deep-1", name: "Deep One" },
];
const browser = { id: "browser", name: "Browser", type: "agent" };
const terminal = { id: "cli", name: "Terminal", type: "terminal" };

// A made-up catalog, one agent in each state the probe can leave it in.
const agents = [
	{ id: "agent-ready", name: "Ready Agent", description: "A made-up agent", featured: true, readiness: { state: "ready", models, modelConfigId: "model", currentModel: "fast-1", probedAt: 1 } },
	{ id: "agent-signin", name: "Signin Agent", description: "Needs the browser", featured: true, readiness: { state: "needsSignIn", authMethods: [browser, terminal], probedAt: 1 } },
	{ id: "agent-gone", name: "Gone Agent", description: "Not installed", featured: true, readiness: { state: "unavailable", reason: "Gone Agent needs Node.js: install it from nodejs.org, then try again.", probedAt: 1 } },
	{ id: "agent-new", name: "New Agent", description: "Never probed", featured: true },
];

function receive(page: Page, messages: Record<string, unknown>[]) {
	return page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, messages);
}

async function openAskBar(page: Page) {
	const world = initialWorld();
	world.settings = { agentsEnabled: "true", agentsLastAgent: "agent-gone" };
	await bootChrome(page, world);
	await receive(page, [
		{ event: "openAskBar", selection: "" },
		{ event: "agentCatalog", agents, projects: ["/Users/example/Code/acme"], home: "/Users/example" },
	]);
	return page.locator(".ask-bar");
}

async function openAgentList(page: Page) {
	const world = initialWorld();
	world.settings = { agentsEnabled: "true" };
	await bootChrome(page, world);
	await receive(page, [{ event: "openSettings" }, { event: "agentCatalog", agents, projects: [], home: "/Users/example" }]);
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();
	await page.locator("[data-setting-id='agentList'] .ui-link-row").click();
}

test("the ask bar never starts on an agent that cannot start, and says why in its menu", async ({ page }) => {
	const bar = await openAskBar(page);
	const picker = bar.getByRole("button", { name: "Agent", exact: true });
	// The last agent used cannot start: the first that can is in front instead.
	await expect(picker).toContainText("Ready Agent");

	await picker.click();
	const gone = page.getByRole("menuitemradio", { name: /Gone Agent/ });
	await expect(gone).toBeDisabled();
	await expect(gone).toContainText("needs Node.js");
	await expect(page.getByRole("menuitemradio", { name: /Signin Agent/ })).toContainText("Needs sign-in");
	await expect(page.getByRole("menuitemradio", { name: /Signin Agent/ })).toBeEnabled();
	await expect(page.getByRole("menuitemradio", { name: /New Agent/ })).toBeEnabled();
});

test("the agent in front is looked at once, and so is each one picked after it", async ({ page }) => {
	const bar = await openAskBar(page);
	await bar.getByRole("button", { name: "Agent", exact: true }).click();
	await page.getByRole("menuitemradio", { name: /New Agent/ }).click();

	const probes = (await sentCommands(page)).filter((command) => command.action === "probeAgent");
	expect(probes.map((command) => command.payload)).toEqual([{ agentId: "agent-ready" }, { agentId: "agent-new" }]);
});

test("the models an agent listed show before the first prompt and go with the start", async ({ page }) => {
	const bar = await openAskBar(page);
	await expect(bar.getByRole("button", { name: "Model", exact: true })).toContainText("Default model");
	await bar.getByRole("button", { name: "Model", exact: true }).click();
	await page.getByRole("menuitemradio", { name: /Deep One/ }).click();
	await bar.getByRole("combobox").fill("Summarize this page");
	await bar.getByRole("button", { name: "Start" }).click();

	const start = (await sentCommands(page)).find((command) => command.action === "startConversation");
	expect(start?.payload).toMatchObject({ agentId: "agent-ready", model: "deep-1" });
});

test("an agent with no models gets no model picker in the ask bar, never an empty one", async ({ page }) => {
	const bar = await openAskBar(page);
	await bar.getByRole("button", { name: "Agent", exact: true }).click();
	await page.getByRole("menuitemradio", { name: /New Agent/ }).click();
	await expect(bar.getByRole("button", { name: "Model", exact: true })).toHaveCount(0);
});

test("Settings shows each agent's state and signs in or checks again from its row", async ({ page }) => {
	await openAgentList(page);
	const rows = page.locator(".settings-section-content .ui-list-row");
	await expect(rows.filter({ hasText: "Ready Agent" })).toContainText("Ready");
	await expect(rows.filter({ hasText: "Gone Agent" })).toContainText("needs Node.js");
	await expect(rows.filter({ hasText: "New Agent" })).not.toContainText("Ready");

	const signin = rows.filter({ hasText: "Signin Agent" });
	await signin.getByRole("button", { name: "Sign In" }).click();
	await signin.getByRole("button", { name: "Actions for Signin Agent" }).click();
	await page.getByRole("menu", { name: "Actions for Signin Agent" }).getByRole("menuitem", { name: "Sign in with Terminal" }).click();
	await rows.filter({ hasText: "Gone Agent" }).getByRole("button", { name: "Actions for Gone Agent" }).click();
	await page.getByRole("menu", { name: "Actions for Gone Agent" }).getByRole("menuitem", { name: "Check Now" }).click();

	const commands = (await sentCommands(page)).filter((command) => command.action === "signInAgent" || command.action === "probeAgent");
	expect(commands.map((command) => [command.action, command.payload])).toEqual([
		["signInAgent", { agentId: "agent-signin", methodId: "browser" }],
		["signInAgent", { agentId: "agent-signin", methodId: "cli" }],
		["probeAgent", { agentId: "agent-gone", force: true }],
	]);
});

test("a probe's answer updates the row without reloading the catalog", async ({ page }) => {
	await openAgentList(page);
	const row = page.locator(".settings-section-content .ui-list-row").filter({ hasText: "New Agent" });
	await receive(page, [{ event: "agentReadiness", agentId: "agent-new", checking: true }]);
	await expect(row).toContainText("Checking...");
	await receive(page, [{ event: "agentReadiness", agentId: "agent-new", checking: false, readiness: { state: "ready", probedAt: 2 } }]);
	await expect(row).toContainText("Ready");
	await expect(row).not.toContainText("Checking...");
});

async function openConversation(page: Page, agent: Record<string, unknown>, updates: Record<string, unknown>[] = []) {
	const world = initialWorld();
	const space = world.activeSpaceId;
	world.tabsBySpace[space].push(tab("tab-agent", space, { title: "Summarize", kind: "agent" } as never));
	world.activeTabBySpace[space] = "tab-agent";
	await bootChrome(page, world);
	await receive(page, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "agentCatalog", agents: [agent], projects: [], home: "/Users/example" },
		{
			event: "conversationsChanged",
			conversations: [{ tabId: "tab-agent", agentId: String(agent.id), title: "Summarize", state: "idle", unread: false, spaceId: space, spaceName: "Work", running: false }],
		},
		{ event: "conversationOpened", tabId: "tab-agent", agentId: agent.id, cwd: "/Users/example/Code/acme", state: "idle", checkpoints: [], updates },
	]);
	await page.locator(".conversation").waitFor({ state: "visible" });
}

test("a conversation not started yet offers the models its agent listed", async ({ page }) => {
	await openConversation(page, agents[0]);
	const picker = page.getByRole("button", { name: "Model", exact: true });
	await expect(picker).toContainText("Fast One");
	await picker.click();
	await page.getByRole("menuitemradio", { name: /Deep One/ }).click();

	const set = (await sentCommands(page)).find((command) => command.action === "setConversationConfig");
	expect(set?.payload).toEqual({ tabId: "tab-agent", configId: "model", value: "deep-1" });
});

test("an agent that lists no models gets a field to type one where the model picker would be", async ({ page }) => {
	await openConversation(page, { id: "agent-bare", name: "Bare Agent", description: "", readiness: { state: "ready", probedAt: 1 } });
	await page.getByRole("button", { name: "Set model" }).click();
	const field = page.getByRole("textbox", { name: "Model ID" });
	await field.fill("two words");
	await field.press("Enter");
	await expect(field).toBeVisible();
	await field.fill("example-model-1");
	await field.press("Enter");
	await expect(field).toBeHidden();

	const set = (await sentCommands(page)).filter((command) => command.action === "setConversationConfig");
	expect(set.map((command) => command.payload)).toEqual([{ tabId: "tab-agent", configId: "model", value: "example-model-1" }]);
});

test("an agent nobody probed shows no model control until its session says what it has", async ({ page }) => {
	await openConversation(page, { id: "agent-new", name: "New Agent", description: "" });
	await expect(page.getByRole("button", { name: "Set model" })).toHaveCount(0);
	await receive(page, [{ event: "conversationUpdate", tabId: "tab-agent", updates: [{
		sessionUpdate: "lilo_session",
		configOptions: [{ id: "effort", name: "Effort", category: "thought_level", type: "select", currentValue: "low", options: [{ value: "low", name: "Low" }, { value: "high", name: "High" }] }],
	}] }]);
	await expect(page.getByRole("button", { name: "Set model" })).toBeVisible();
});
