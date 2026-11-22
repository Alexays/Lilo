import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow, type PostedMessage } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

function activity(
	moods: Record<string, string>,
	...clients: { name: string; busy?: boolean; actingTabIds?: string[]; spaceIds?: string[] }[]
): void {
	receive({
		event: "agentActivity",
		clients: clients.map((client) => ({ busy: false, actingTabIds: [], spaceIds: ["agents"], ...client })),
		agentsSpaceIds: ["agents", "agents-pro"],
		hiddenAgentsSpaceIds: [],
		moods,
	});
}

function snapshot(): void {
	receive({
		event: "agentClientsLoaded",
		clients: [
			{ id: "claudeDesktop", configured: true, icon: "data:claude" },
			{ id: "cursor", configured: true, icon: "data:cursor" },
		],
		allowed: [
			{ name: "claude-ai", displayName: "Claude", lastSeen: null, client: "claudeDesktop" },
			{ name: "cursor-vscode", displayName: "Cursor", lastSeen: null, client: "cursor" },
			{ name: "my-script", displayName: "my-script", lastSeen: null, client: null },
		],
	});
}

async function loadAgentsStore() {
	const loadStore = await freshStores();
	(await loadStore("/src/stores/settings.svelte.ts")).initSettingsStore();
	const store = await loadStore("/src/stores/agents.svelte.ts");
	store.initAgentsStore();
	return store;
}

const iconRequests = (posted: PostedMessage[]) =>
	posted.filter((message) => message.action === "getAgentClients").length;

test("an unknown agent asks for the client list only once", async () => {
	const posted = stubBridgeWindow();
	const store = await loadAgentsStore();
	snapshot();
	const before = iconRequests(posted);

	activity({}, { name: "my-script" });
	activity({}, { name: "other-tool" });
	activity({}, { name: "other-tool", busy: true });
	assert.equal(iconRequests(posted), before + 1);
	assert.ok(store.isAgentsSpace("agents-pro"));
});

test("a space keeps its mood between two calls while its agent still acts, then goes idle", async () => {
	stubBridgeWindow();
	const store = await loadAgentsStore();

	activity({ agents: "reading" }, { name: "claude-ai", busy: true, actingTabIds: ["tab"] });
	assert.equal(store.getAgentMood("agents"), "reading");
	activity({}, { name: "claude-ai", actingTabIds: ["tab"] });
	assert.equal(store.getAgentMood("agents"), "reading");
	activity({ agents: "typing" }, { name: "claude-ai", busy: true, actingTabIds: ["tab"] });
	assert.equal(store.getAgentMood("agents"), "typing");
	activity({}, { name: "claude-ai" });
	assert.equal(store.getAgentMood("agents"), undefined);
});

test("each Agents space has the mood of the agents working in it", async () => {
	stubBridgeWindow();
	const store = await loadAgentsStore();

	activity(
		{ "agents-pro": "loading" },
		{ name: "claude-ai", busy: true, actingTabIds: ["tab"], spaceIds: ["agents-pro"] },
		{ name: "cursor-vscode" },
	);
	assert.equal(store.getAgentMood("agents-pro"), "loading");
	assert.equal(store.getAgentMood("agents"), undefined);
});
