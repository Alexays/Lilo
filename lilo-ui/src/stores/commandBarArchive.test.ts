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

const archived = [
	{ id: "new", url: "https://news.example/today", title: "Today's news", archivedAt: Date.now() - 3_600_000 },
	{ id: "old", url: "https://docs.example/guide", title: "Guide", archivedAt: Date.now() - 3 * 86_400_000 },
];

function archiveOutput(input: string) {
	return computeResults(
		{ parsed: parseInput(input), historyResults: [], searchSuggestions: [], searchEngine: "google", archivedTabs: archived },
		0,
	);
}

test("< lists the archived tabs as sent, newest first, then offers to clear them", () => {
	const output = archiveOutput("<");

	assert.deepEqual(output.sections.map((section) => section.id), ["archived"]);
	assert.deepEqual(output.results.map((result) => result.kind), ["archivedTab", "archivedTab", "clearArchive"]);
	assert.deepEqual(output.results.slice(0, 2).map((result) => result.payload.id), ["new", "old"]);
});

test("typing after < filters the archive by title or address, without the clear row", () => {
	assert.deepEqual(archiveOutput("< docs").results.map((result) => result.payload.id), ["old"]);
	assert.deepEqual(archiveOutput("<news").results.map((result) => result.payload.id), ["new"]);
	assert.deepEqual(archiveOutput("< nothing").results, []);
});

test("opening the archive asks native once, and picking a row reopens it", async () => {
	const { freshStores, stubBridgeWindow } = await import("./testHarness");
	const sent = stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const commandBar = await loadStore("/src/stores/commandBar.svelte.ts");
	commandBar.initCommandBarStore();
	const receive = (
		globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }
	).window.__lilo!.receive;

	commandBar.openCommandBar("<");
	commandBar.setQuery("< gui");
	assert.equal(sent.filter((message) => message.action === "loadArchivedTabs").length, 1);

	receive({ event: "archivedTabs", tabs: archived, favicons: {} });
	const results = commandBar.getResults() as Array<{ kind: string; payload: { id: string } }>;
	assert.deepEqual(results.map((result) => result.payload.id), ["old"]);

	commandBar.executeSelected();
	assert.deepEqual(sent.at(-1), { action: "restoreArchivedTabs", payload: { ids: ["old"] } });
	assert.equal(commandBar.isCommandBarOpen(), false);
});
