import test from "node:test";
import assert from "node:assert/strict";

(globalThis as { window?: unknown }).window ??= {
	__liloBootstrapEvents: [],
};
type StateRune = (<T>(value: T) => T) & { raw: <T>(value: T) => T };
(globalThis as { $state?: StateRune }).$state ??= Object.assign(
	<T>(value: T) => value,
	{ raw: <T>(value: T) => value },
);
// The command bar store reads the pager's paged Spaces, a module-level $derived.
type DerivedRune = (<T>(value: T) => T) & { by: <T>(fn: () => T) => T };
(globalThis as { $derived?: DerivedRune }).$derived ??= Object.assign(
	<T>(value: T) => value,
	{ by: <T>(fn: () => T) => fn() },
);

const { parseInput } = await import("../lib/inputParser");
const { computeResults } = await import("./commandBarSearch.svelte");
type BridgeTerminalSummary = import("../lib/bridge/protocol").BridgeTerminalSummary;

function terminal(tabId: string, overrides: Partial<BridgeTerminalSummary> = {}): BridgeTerminalSummary {
	return {
		tabId,
		title: tabId,
		command: "",
		state: "idle",
		awaitingInputSince: 0,
		startedAt: 0,
		exitCode: 0,
		duration: 0,
		gitBranch: "",
		spaceId: "work",
		spaceName: "Work",
		...overrides,
	};
}

function terminalOutput(input: string, terminals: BridgeTerminalSummary[]) {
	return computeResults(
		{
			parsed: parseInput(input),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
			terminalCompletions: [{ command: "make test", source: "history" }],
			terminals,
		},
		0,
	);
}

test("an empty > lists terminals first, the ones waiting for an answer longest first", () => {
	const now = Date.now();
	const output = terminalOutput(">", [
		terminal("prompt"),
		terminal("failed", { state: "failed", exitCode: 101 }),
		terminal("server", { state: "busy", command: "npm run dev", startedAt: now - 60_000 }),
		terminal("recent-agent", { state: "waiting", awaitingInputSince: now - 1_000 }),
		terminal("old-agent", { state: "waiting", awaitingInputSince: now - 240_000 }),
	]);

	assert.deepEqual(output.sections.map((section) => section.id), ["terminals", "terminal"]);
	assert.deepEqual(
		output.results.filter((result) => result.kind === "terminalTab").map((result) => result.payload.tabId),
		["old-agent", "recent-agent", "server", "failed", "prompt"],
	);
});

test("typed text stays a command to run first, and filters the terminals by title, command, branch or Space", () => {
	const output = terminalOutput(">fix", [
		terminal("by-branch", { gitBranch: "fix-locks" }),
		terminal("by-title", { title: "fix tests" }),
		terminal("unrelated", { title: "server", gitBranch: "main", spaceName: "Home" }),
	]);

	assert.deepEqual(output.sections.map((section) => section.id), ["terminal", "terminals"]);
	assert.equal(output.results[0].kind, "terminal");
	assert.deepEqual(
		output.results.filter((result) => result.kind === "terminalTab").map((result) => result.payload.tabId),
		["by-branch", "by-title"],
	);
});

test("> lists closed terminals last, newest first, and filters them like the open ones", () => {
	const now = Date.now();
	const closed = (index: number, folder: string, resumeCommand: string) => ({
		index, title: "claude", resumeCommand, gitBranch: "main", folder, closedAt: now - 120_000, hasScreen: true, spaceName: "Work",
	});
	const run = (input: string) => computeResults(
		{
			parsed: parseInput(input),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
			terminalCompletions: [],
			terminals: [terminal("open")],
			closedTerminals: [closed(0, "site", "claude --continue"), closed(1, "lilo", "npm run dev")],
		},
		0,
	);

	const empty = run(">");
	assert.deepEqual(empty.sections.map((section) => section.id), ["terminals", "closedTerminals"]);
	const reopen = empty.results.filter((result) => result.kind === "closedTerminal");
	assert.deepEqual(reopen.map((result) => result.payload.index), [0, 1]);
	assert.match(reopen[0].subtitle ?? "", /claude --continue/);

	const filtered = run("> npm");
	assert.deepEqual(filtered.results.filter((result) => result.kind === "closedTerminal").map((result) => result.payload.index), [1]);
});

test("an open bar refreshes its terminal list from terminalActivity without asking native again", async () => {
	const { freshStores, stubBridgeWindow } = await import("./testHarness");
	const sent = stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const commandBar = await loadStore("/src/stores/commandBar.svelte.ts");
	commandBar.initCommandBarStore();
	const receive = (
		globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }
	).window.__lilo!.receive;
	const now = Date.now();
	const tabIds = () =>
		(commandBar.getResults() as Array<{ kind: string; payload: { tabId: string } }>)
			.filter((result) => result.kind === "terminalTab")
			.map((result) => result.payload.tabId);

	commandBar.openCommandBar(">");
	receive({
		event: "terminalCompletionResults",
		query: "",
		items: [],
		terminals: [terminal("a"), terminal("b", { state: "waiting", awaitingInputSince: now })],
		closedTerminals: [],
	});
	assert.deepEqual(tabIds(), ["b", "a"]);

	const requests = sent.length;
	receive({
		event: "terminalActivity",
		terminals: [terminal("a", { state: "waiting", awaitingInputSince: now }), terminal("b"), terminal("c")],
	});
	assert.deepEqual(tabIds(), ["a", "b", "c"]);
	assert.equal(sent.length, requests);

	commandBar.closeCommandBar();
	receive({ event: "terminalActivity", terminals: [terminal("d")] });
	commandBar.openCommandBar(">");
	assert.deepEqual(tabIds(), []);
});
