import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const models = [
	{ id: "fast-1", name: "Fast One", description: "Small and quick" },
	{ id: "deep-1", name: "Deep One" },
];
const browser = { id: "browser", name: "Browser", type: "agent" };
const terminal = { id: "cli", name: "Terminal", type: "terminal" };

// A made-up catalog, one agent in each state a start or a check can leave it in.
const agents = [
	{ id: "agent-ready", name: "Ready Agent", description: "A made-up agent", featured: true, readiness: { state: "ready", models, modelConfigId: "model", currentModel: "fast-1" } },
	{ id: "agent-signin", name: "Signin Agent", description: "Needs the browser", featured: true, readiness: { state: "needsSignIn", authMethods: [browser, terminal] } },
	{ id: "agent-gone", name: "Gone Agent", description: "Not installed", featured: true, readiness: { state: "unavailable", reason: "Gone Agent needs Node.js: install it from nodejs.org, then try again." } },
	{ id: "agent-new", name: "New Agent", description: "Never started", featured: true },
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

test("the ask bar keeps every agent pickable, says what is in its way, and starts none", async ({ page }) => {
	const bar = await openAskBar(page);
	const picker = bar.getByRole("button", { name: "Agent", exact: true });
	// The last agent used could not start when last checked: it stays in front.
	await expect(picker).toContainText("Gone Agent");

	await picker.click();
	const gone = page.getByRole("menuitemradio", { name: /Gone Agent/ });
	await expect(gone).toBeEnabled();
	await expect(gone).toContainText("needs Node.js");
	await expect(page.getByRole("menuitemradio", { name: /Signin Agent/ })).toContainText("Needs sign-in");
	await page.getByRole("menuitemradio", { name: /New Agent/ }).click();

	expect((await sentCommands(page)).filter((command) => command.action === "checkAgent")).toEqual([]);
});

test("the models an agent listed show before the first prompt and go with the start", async ({ page }) => {
	const bar = await openAskBar(page);
	await bar.getByRole("button", { name: "Agent", exact: true }).click();
	await page.getByRole("menuitemradio", { name: /Ready Agent/ }).click();
	await expect(bar.getByRole("button", { name: "Model", exact: true })).toContainText("Fast One");
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

	const commands = (await sentCommands(page)).filter((command) => command.action === "signInAgent" || command.action === "checkAgent");
	expect(commands.map((command) => [command.action, command.payload])).toEqual([
		["signInAgent", { agentId: "agent-signin", methodId: "browser" }],
		["signInAgent", { agentId: "agent-signin", methodId: "cli" }],
		["checkAgent", { agentId: "agent-gone" }],
	]);
});

test("a check's answer updates the row without reloading the catalog", async ({ page }) => {
	await openAgentList(page);
	const row = page.locator(".settings-section-content .ui-list-row").filter({ hasText: "New Agent" });
	await receive(page, [{ event: "agentReadiness", agentId: "agent-new", checking: true }]);
	await expect(row).toContainText("Checking...");
	await receive(page, [{ event: "agentReadiness", agentId: "agent-new", checking: false, readiness: { state: "ready" } }]);
	await expect(row).toContainText("Ready");
	await expect(row).not.toContainText("Checking...");
});
