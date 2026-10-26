import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow, type PostedMessage } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

function activity(...clients: { name: string; busy?: boolean; spaceIds?: string[] }[]): void {
	receive({
		event: "agentActivity",
		clients: clients.map((client) => ({ busy: false, actingTabIds: [], spaceIds: ["agents"], ...client })),
		agentsSpaceIds: ["agents", "agents-pro"],
		hiddenAgentsSpaceIds: [],
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

test("a connected agent shows its app icon once the client list arrives", async () => {
	const posted = stubBridgeWindow();
	const store = await loadAgentsStore();
	const before = iconRequests(posted);

	activity({ name: "claude-ai" });
	assert.equal(iconRequests(posted), before + 1);
	assert.equal(store.getAgentIcons("agents"), undefined);

	snapshot();
	assert.deepEqual(store.getAgentIcons("agents"), ["data:claude"]);
});

test("an unknown agent keeps the robot and asks for the client list only once", async () => {
	const posted = stubBridgeWindow();
	const store = await loadAgentsStore();
	snapshot();
	const before = iconRequests(posted);

	activity({ name: "my-script" });
	activity({ name: "other-tool" });
	activity({ name: "other-tool", busy: true });
	assert.equal(store.getAgentIcons("agents"), undefined);
	assert.equal(iconRequests(posted), before + 1);
});

test("the acting agent comes last, in front of the others", async () => {
	stubBridgeWindow();
	const store = await loadAgentsStore();
	snapshot();

	activity({ name: "claude-ai", busy: true }, { name: "cursor-vscode" });
	assert.deepEqual(store.getAgentIcons("agents"), ["data:cursor", "data:claude"]);
	activity({ name: "claude-ai" }, { name: "cursor-vscode", busy: true });
	assert.deepEqual(store.getAgentIcons("agents"), ["data:claude", "data:cursor"]);
});

test("each Agents space shows the agents working in it", async () => {
	stubBridgeWindow();
	const store = await loadAgentsStore();
	snapshot();

	activity({ name: "claude-ai", busy: true, spaceIds: ["agents-pro"] }, { name: "cursor-vscode" });
	assert.deepEqual(store.getAgentIcons("agents"), ["data:cursor"]);
	assert.deepEqual(store.getAgentIcons("agents-pro"), ["data:claude"]);
	assert.ok(store.isAgentsSpace("agents-pro"));
});
