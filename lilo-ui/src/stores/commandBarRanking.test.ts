import test from "node:test";
import assert from "node:assert/strict";
import type { BridgeInitialStatePayload, BridgeSpaceSnapshot } from "../lib/bridge/protocol";
import { tab, treeItem } from "./testFixtures";

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
const { applySpaceInitialState } = await import("./spaces.svelte");
const { applyProfileInitialState } = await import("./profiles.svelte");
const { applySidebarFolderInitialState, applySidebarTabInitialState } = await import("./sidebar.svelte");
const { computeResults, noteActiveTab, toHistoryResults } = await import("./commandBarSearch.svelte");
type CommandResult = import("./commandBarSearch.svelte").CommandResult;

const DAY = 86_400_000;

function space(id: string, name: string, icon: string, profileId: string, isPrivate = false): BridgeSpaceSnapshot {
	return { id, name, icon, color: "#5865f2", profileId, isPrivate, sortOrder: 0 };
}

const spaces = [
	space("home", "Home", "🏠", "personal"),
	space("work", "Work", "💼", "job"),
	space("side", "Side Project", "🧪", "personal"),
	space("secret", "Secret", "🕶️", "personal", true),
];

function seed(tabs: BridgeInitialStatePayload["tabs"], treeItems: BridgeInitialStatePayload["treeItems"] = []): void {
	const initial = {
		activeSpaceId: "home",
		activeTabId: "active",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces,
		profiles: [
			{ id: "personal", name: "Personal", isDefault: true },
			{ id: "job", name: "Acme", isDefault: false },
		],
		tabs: [tab("active", "home", { title: "Active" }), ...tabs],
		treeItems,
		folders: [],
	} as unknown as BridgeInitialStatePayload;
	applySpaceInitialState(initial);
	applyProfileInitialState(initial);
	applySidebarTabInitialState(initial);
	applySidebarFolderInitialState(initial);
}

function search(input: string, historyResults: CommandResult[] = []) {
	return computeResults({ parsed: parseInput(input), historyResults, searchSuggestions: [], searchEngine: "google", spaces }, 0);
}

test("history ranks by match plus frecency: a page visited often lately beats a closer match seen once long ago", () => {
	const now = Date.UTC(2026, 0, 31);
	const items = [
		{ id: "old", title: "Rust book", url: "https://old.example/rust", visitCount: 1, lastVisitedAt: now - 60 * DAY },
		{ id: "hot", title: "The Rust forum", url: "https://hot.example/", visitCount: 40, lastVisitedAt: now - DAY },
	];

	assert.deepEqual(toHistoryResults(items, "rust", now).map((result) => result.id), ["history-hot", "history-old"]);
	// Without a query the host's order (newest first) stands.
	assert.deepEqual(toHistoryResults(items, "", now).map((result) => result.id), ["history-old", "history-hot"]);
});

test("history: a row the fuzzy match misses still ranks on frecency, below real matches", () => {
	const now = Date.UTC(2026, 0, 31);
	const results = toHistoryResults([
		{ id: "token", title: "Unrelated", url: "https://elsewhere.example/", visitCount: 3, lastVisitedAt: now },
		{ id: "match", title: "Kubernetes docs", url: "https://k8s.example/", visitCount: 1, lastVisitedAt: now - 30 * DAY },
	], "kube", now);

	assert.deepEqual(results.map((result) => result.id), ["history-match", "history-token"]);
});

test("tabs: of two equal matches, the one activated last ranks first", () => {
	seed([
		tab("notes-a", "home", { title: "Notes", url: "https://a.notes.example/" }),
		tab("notes-b", "home", { title: "Notes", url: "https://b.notes.example/" }),
	]);
	const order = () => search("@notes").results.map((result) => result.id);
	assert.deepEqual(order(), ["tab-notes-a", "tab-notes-b"]);

	noteActiveTab("notes-b", Date.now() - DAY);
	noteActiveTab("active", Date.now());
	assert.deepEqual(order(), ["tab-notes-b", "tab-notes-a"]);
	// The empty tab list ranks the same way.
	assert.deepEqual(search("@").results.map((result) => result.id).slice(0, 2), ["tab-notes-b", "tab-notes-a"]);
});

test("bookmarks: of two equal matches, the one whose page history visits more ranks first", () => {
	seed(
		[
			tab("guide-a", "home", { title: "Guide", url: "https://a.guide.example/", isBookmarked: true }),
			tab("guide-b", "home", { title: "Guide", url: "https://b.guide.example/", isBookmarked: true }),
		],
		[treeItem("guide-a", "home", 0, "bookmarked"), treeItem("guide-b", "home", 1, "bookmarked")],
	);
	const history = toHistoryResults(
		[{ id: "b", title: "Guide", url: "https://b.guide.example/", visitCount: 12, lastVisitedAt: Date.now() }],
		"guide",
	);

	assert.deepEqual(search("#guide").results.map((result) => result.id), ["bookmark-guide-a", "bookmark-guide-b"]);
	assert.deepEqual(search("#guide", history).results.map((result) => result.id), ["bookmark-guide-b", "bookmark-guide-a"]);
});

test("typing a Space's name offers to switch to it, with its emoji and profile; never the active or a private one", () => {
	seed([]);

	const work = search("work").sections.find((section) => section.id === "spaces")?.items.map((entry) => entry.result);
	assert.deepEqual(work?.map(({ kind, title, icon, subtitle, payload }) => ({ kind, title, icon, subtitle, spaceId: payload.spaceId })), [
		{ kind: "space", title: "Work", icon: "💼", subtitle: "Acme", spaceId: "work" },
	]);
	assert.equal(search("home").results.some((result) => result.kind === "space"), false);
	assert.equal(search("secret").results.some((result) => result.kind === "space"), false);
	// A profile's name finds its Spaces: switching profile is switching to one of them.
	assert.deepEqual(
		search("acme").results.filter((result) => result.kind === "space").map((result) => result.payload.spaceId),
		["work"],
	);
});

test("the : scope lists Switch to and Move Tab to rows for the matching Spaces", () => {
	seed([]);

	const rows = search(":work").results.filter((result) => result.kind === "space" || result.kind === "moveToSpace");
	assert.deepEqual(rows.map(({ kind, title }) => ({ kind, title })), [
		{ kind: "space", title: "Switch to Work" },
		{ kind: "moveToSpace", title: "Move Tab to Work" },
	]);
	assert.equal(rows[1]?.payload.tabId, undefined, "a Move row without a tab moves the current one");
	assert.deepEqual(
		search(":move").results.filter((result) => result.kind === "moveToSpace").map((result) => result.payload.spaceId),
		["work", "side"],
	);
});

test("moving a tab lists only the Spaces it can go to, all of them before typing", () => {
	seed([tab("docs", "home", { title: "Docs" })]);
	const picker = (query: string) => computeResults(
		{ parsed: parseInput(query), historyResults: [], searchSuggestions: [], searchEngine: "google", spaces, moveTabId: "docs" },
		0,
	);

	assert.deepEqual(picker("").results.map(({ kind, title, payload }) => ({ kind, title, ...payload })), [
		{ kind: "moveToSpace", title: "Work", spaceId: "work", tabId: "docs" },
		{ kind: "moveToSpace", title: "Side Project", spaceId: "side", tabId: "docs" },
	]);
	assert.deepEqual(picker("side").results.map((result) => result.payload.spaceId), ["side"]);
});

test("a history row for a page open in another tab switches to that tab instead of opening it twice", () => {
	seed([tab("waybar", "home", { title: "Waybar", url: "https://github.com/Alexays/Waybar" })]);
	const history = (query: string) => toHistoryResults([
		{ id: "w", title: "GitHub - Alexays/Waybar: Highly customizable bar", url: "https://github.com/Alexays/Waybar/", visitCount: 9, lastVisitedAt: Date.now() },
	], query);

	const typed = search("customizable", history("customizable")).results[0];
	assert.deepEqual({ kind: typed?.kind, title: typed?.title, payload: typed?.payload }, {
		kind: "tab", title: "GitHub - Alexays/Waybar: Highly customizable bar", payload: { tabId: "waybar" },
	});
	assert.ok(typed?.titleHighlights?.length, "keeps the history row's highlights");

	const recent = search("", history("")).results.filter((result) => result.url?.includes("Waybar"));
	assert.deepEqual(recent.map((result) => [result.kind, result.payload.tabId]), [["tab", "waybar"]], "listed once, as the open tab");
});

test("history the typed words match only out of order stays below the web search; a real match stays above", () => {
	seed([]);
	const loose = toHistoryResults(
		[{ id: "c", title: "Flexbox guide", url: "https://css.example/center-div-how-to", visitCount: 3, lastVisitedAt: Date.now() }],
		"how to center a div",
	);
	assert.deepEqual(search("how to center a div", loose).sections.map((section) => section.id), ["search", "history"]);

	const real = toHistoryResults(
		[{ id: "n", title: "Hacker News", url: "https://news.ycombinator.com/", visitCount: 50, lastVisitedAt: Date.now() }],
		"news",
	);
	assert.equal(search("news", real).results[0]?.title, "Hacker News");
});

test("a history site whose address starts with the query beats a tab the query only fuzzy-matches", () => {
	const github = () => toHistoryResults(
		[{ id: "g", title: "GitHub", url: "https://www.github.com/", visitCount: 30, lastVisitedAt: Date.now() }],
		"gith",
	);

	seed([tab("hacks", "home", { title: "Legit hacks", url: "https://hacks.example/" })]);
	assert.equal(search("gith", github()).results[0]?.title, "GitHub");

	// A tab the query starts as strongly, by title or by host, keeps the lead.
	seed([tab("issues", "home", { title: "GitHub issues", url: "https://issues.example/" })]);
	assert.equal(search("gith", github()).results[0]?.id, "tab-issues");
	seed([tab("waybar", "home", { title: "Alexays/Waybar", url: "https://github.com/Alexays/Waybar" })]);
	assert.equal(search("gith", github()).results[0]?.id, "tab-waybar");
});

test("outside the : scope, actions need the query to start a word of their name or keywords", () => {
	seed([]);
	const actions = (input: string) => search(input).results.filter((result) => result.kind === "action").map((result) => result.title);

	assert.equal(actions("news").includes("New Split View"), false);
	assert.equal(actions("news").includes("New Space"), false);
	assert.deepEqual(actions("ewspl"), []);
	assert.ok(actions("split").includes("New Split View"));
	assert.ok(actions(":news").includes("New Split View"), "the : scope keeps fuzzy matching");
});
