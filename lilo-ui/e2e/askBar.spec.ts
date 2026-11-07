import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";
import { tab } from "../src/stores/testFixtures";

const agents = [
	{ id: "claude-acp", name: "Claude Agent", description: "" },
	{ id: "codex-acp", name: "Codex", description: "" },
];

function receive(page: Page, messages: Record<string, unknown>[]) {
	return page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, messages);
}

async function openAskBar(page: Page) {
	await bootChrome(page, initialWorld());
	await receive(page, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "openAskBar", selection: "" },
		{ event: "agentCatalog", agents, projects: ["/Users/example/Code/acme"], home: "/Users/example" },
	]);
	return page.locator(".ask-bar");
}

test("picking an agent from the ask bar's menu selects it and keeps the bar open", async ({ page }) => {
	const bar = await openAskBar(page);
	const picker = bar.getByRole("button", { name: "Agent", exact: true });
	await picker.click();
	await page.getByRole("menuitemradio", { name: "Codex" }).click();

	await expect(bar).toBeVisible();
	await expect(picker).toContainText("Codex");
});

test("a conversation starts without a folder, the agent working in one of its own", async ({ page }) => {
	const bar = await openAskBar(page);
	await expect(bar.getByRole("button", { name: "Project", exact: true })).toContainText("No Folder");
	await bar.getByRole("combobox").fill("Summarize this page");
	await bar.getByRole("button", { name: "Start" }).click();

	const start = (await sentCommands(page)).find((command) => command.action === "startConversation");
	expect(start?.payload).toMatchObject({ agentId: "claude-acp", cwd: "", text: "Summarize this page", background: false });
	expect(start?.payload).not.toHaveProperty("ownCopy");
});

test("a sign-in shows as the reply under the prompt, which waits for it instead of failing", async ({ page }) => {
	const world = initialWorld();
	const space = world.activeSpaceId;
	world.tabsBySpace[space].push(tab("tab-agent", space, { title: "Summarize", kind: "agent" } as never));
	world.activeTabBySpace[space] = "tab-agent";
	await bootChrome(page, world);
	await receive(page, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "agentCatalog", agents, projects: [], home: "/Users/example" },
		{
			event: "conversationsChanged",
			conversations: [{ tabId: "tab-agent", agentId: "codex-acp", title: "Summarize", state: "busy", unread: false, spaceId: space, spaceName: "Work", running: true }],
		},
		{
			event: "conversationOpened", tabId: "tab-agent", agentId: "codex-acp", cwd: "/Users/example/Code/acme", state: "busy", checkpoints: [],
			updates: [
				{ sessionUpdate: "lilo_user", text: "Summarize this page", context: [] },
				{ sessionUpdate: "lilo_signing_in", terminal: true },
			],
		},
	]);
	const activity = page.locator(".activity");
	await expect(activity).toContainText("Signing in to Codex");
	await expect(activity).toContainText("terminal tab Lilo opened");
	await expect(page.getByRole("alert")).toHaveCount(0);

	await receive(page, [{ event: "conversationUpdate", tabId: "tab-agent", updates: [{ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Here is the summary." } }] }]);
	await expect(page.getByText("Here is the summary.")).toBeVisible();
	await expect(activity).not.toContainText("Signing in");
	await expect(activity).toContainText("Working");
});

test("a terminal sign-in shows its screen as a card in the thread, which answers it", async ({ page }) => {
	const world = initialWorld();
	const space = world.activeSpaceId;
	world.tabsBySpace[space].push(tab("tab-agent", space, { title: "Summarize", kind: "agent" } as never));
	world.activeTabBySpace[space] = "tab-agent";
	await bootChrome(page, world);
	await receive(page, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "agentCatalog", agents, projects: [], home: "/Users/example" },
		{
			event: "conversationsChanged",
			conversations: [{ tabId: "tab-agent", agentId: "codex-acp", title: "Summarize", state: "busy", unread: false, spaceId: space, spaceName: "Work", running: true }],
		},
		{
			event: "conversationOpened", tabId: "tab-agent", agentId: "codex-acp", cwd: "/Users/example/Code/acme", state: "busy", checkpoints: [],
			updates: [
				{ sessionUpdate: "lilo_user", text: "Summarize this page", context: [] },
				{ sessionUpdate: "lilo_signing_in", terminal: true },
				{ sessionUpdate: "lilo_sign_in_screen", lines: [], question: "Select a login method:", choices: [{ key: "1", label: "Subscription" }, { key: "2", label: "API key" }] },
			],
		},
	]);
	const card = page.getByRole("group", { name: "Signing in to Codex" });
	await expect(card).toContainText("Select a login method:");
	await card.getByRole("button", { name: "API key" }).click();

	await receive(page, [{
		event: "conversationUpdate", tabId: "tab-agent",
		updates: [{ sessionUpdate: "lilo_sign_in_screen", lines: ["Paste code here if prompted >"], question: "", choices: [] }],
	}]);
	await card.getByRole("textbox", { name: "Answer to the sign-in" }).fill("code-123");
	await card.getByRole("button", { name: "Send" }).click();
	await card.getByRole("button", { name: "Open in Terminal" }).click();

	const answers = (await sentCommands(page)).filter((command) => command.action === "answerConversationSignIn").map((command) => command.payload);
	expect(answers).toEqual([{ tabId: "tab-agent", text: "2" }, { tabId: "tab-agent", text: "code-123\r" }]);
	expect((await sentCommands(page)).some((command) => command.action === "openConversationSignInTerminal")).toBe(true);

	await receive(page, [{ event: "conversationUpdate", tabId: "tab-agent", updates: [{ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Here is the summary." } }] }]);
	await expect(card).toHaveCount(0);
});
