import test from "node:test";
import assert from "node:assert/strict";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";

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
const { applySidebarFolderInitialState, applySidebarTabInitialState } = await import("./sidebar.svelte");
const {
	computeResults,
	getLocalHostCompletion,
	normalizeSearchSuggestions,
} = await import(
	"./commandBarSearch.svelte"
);
type CommandResult = import("./commandBarSearch.svelte").CommandResult;

function resetTabs(): void {
	const initialState = {
		activeSpaceId: "space",
		activeTabId: "active-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [
			tab("active-tab", "Active", "https://active.example"),
			tab("ash-tab", "Ash Speed Test", "https://ash-speed.example.com/"),
			tab("docs-tab", "Docs", "https://docs.example"),
		],
		treeItems: [],
		folders: [],
	};

	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
}

function tab(id: string, title: string, url: string) {
	return {
		id,
		spaceId: "space",
		url,
		title,
		isLoading: false,
		canGoBack: false,
		canGoForward: false,
		progress: 1,
		isPinned: false,
		isBookmarked: false,
		isClosed: false,
		isAudioPlaying: false,
		isMuted: false,
		isMicrophoneActive: false,
		isMicrophoneMuted: false,
		isCameraActive: false,
		isScreenSharing: false,
		hasNavigationError: false,
		navigationErrorCode: 0,
		navigationErrorDomain: "",
		navigationErrorDescription: "",
		navigationErrorURL: "",
	};
}

function historyResult(id: string, title: string, url: string): CommandResult {
	return {
		id,
		kind: "history",
		title,
		subtitle: url,
		url,
		payload: {},
	};
}

test("all-scope search: locked folder tabs never surface by title", () => {
	resetTabs();
	const initialState = {
		activeSpaceId: "space",
		activeTabId: "active-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: "space", name: "Space", icon: "S", color: "#5865f2", profileId: "profile", isPrivate: false, sortOrder: 0 }],
		tabs: [
			tab("active-tab", "Active", "https://active.example"),
			{ ...tab("bank-tab", "Bank accounts", "https://bank.example"), groupId: "vault" },
		],
		treeItems: [],
		folders: [
			{ id: "vault", spaceId: "space", name: "Vault", color: "#f06aa6", isCollapsed: true, isLocked: true, lock: { allowsBiometrics: false, biometricsAvailable: false } },
		],
	};
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState(initialState);

	const output = computeResults(
		{ parsed: parseInput("bank"), historyResults: [], searchSuggestions: [], searchEngine: "google" },
		0,
	);

	assert.equal(output.results.some((result) => result.title.includes("Bank") || result.url === "https://bank.example"), false);
	const locked = output.results.filter((result) => result.kind === "lockedFolder");
	assert.equal(locked.length, 1);
	assert.equal(locked[0]?.payload.folderId, "vault");
	resetTabs();
});

test("all-scope search: a locked folder needs a real match, not letters scattered across a URL", () => {
	resetTabs();
	const url = "https://shop.example.com/bons-plans/kitchen-crepe-maker-40-cm";
	const initialState = {
		activeSpaceId: "space",
		activeTabId: "active-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: "space", name: "Space", icon: "S", color: "#5865f2", profileId: "profile", isPrivate: false, sortOrder: 0 }],
		tabs: [
			tab("active-tab", "Active", "https://active.example"),
			{ ...tab("deal-tab", "Crepe maker", url), groupId: "vault" },
		],
		treeItems: [],
		folders: [
			{ id: "vault", spaceId: "space", name: "🍳", color: "#f06aa6", isCollapsed: true, isLocked: true, lock: { allowsBiometrics: false, biometricsAvailable: false } },
		],
	};
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState(initialState);

	const lockedFor = (query: string) => computeResults(
		{ parsed: parseInput(query), historyResults: [], searchSuggestions: [], searchEngine: "google" },
		0,
	).results.filter((result) => result.kind === "lockedFolder");

	assert.equal(lockedFor("monip").length, 0);
	const locked = lockedFor("crepe");
	assert.equal(locked.length, 1);
	assert.equal(locked[0]?.icon, "🍳");
	resetTabs();
});

test("all-scope search: a tab in a subfolder of a locked folder stays hidden too", () => {
	resetTabs();
	const initialState: BridgeInitialStatePayload = {
		activeSpaceId: "space",
		activeTabId: "active-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: "space", name: "Space", icon: "S", color: "#5865f2", profileId: "profile", isPrivate: false, sortOrder: 0 }],
		tabs: [
			tab("active-tab", "Active", "https://active.example"),
			{ ...tab("tax-tab", "Tax return", "https://taxes.example"), groupId: "taxes" },
		],
		folders: [
			{ id: "vault", spaceId: "space", name: "Vault", color: "#f06aa6", isCollapsed: true, isLocked: true, lock: { allowsBiometrics: false, biometricsAvailable: false } },
			{ id: "taxes", spaceId: "space", name: "Taxes", color: "#5b7cff", isCollapsed: false },
		],
		treeItems: [
			{ id: "vault", spaceId: "space", kind: "folder", itemId: "vault", parentFolderId: null, section: "unpinned", sortOrder: 0 },
			{ id: "taxes", spaceId: "space", kind: "folder", itemId: "taxes", parentFolderId: "vault", section: "unpinned", sortOrder: 0 },
			{ id: "tax-tab", spaceId: "space", kind: "tab", itemId: "tax-tab", parentFolderId: "taxes", section: "unpinned", sortOrder: 0 },
		],
	};
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState(initialState);

	const output = computeResults(
		{ parsed: parseInput("tax"), historyResults: [], searchSuggestions: [], searchEngine: "google" },
		0,
	);

	assert.equal(output.results.some((result) => result.url === "https://taxes.example"), false);
	assert.deepEqual(output.results.filter((r) => r.kind === "lockedFolder").map((r) => r.payload.folderId), ["vault"]);
	resetTabs();
});

test("all-scope empty state: history, tabs, bookmarks, then two quick actions", () => {
	resetTabs();

	const output = computeResults(
		{
			parsed: parseInput(""),
			historyResults: [historyResult("history-1", "Recent", "https://recent.example")],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	assert.deepEqual(
		output.sections.map((s) => s.id),
		["history", "tabs", "actions"],
	);
	const actions = output.sections.find((s) => s.id === "actions");
	assert.ok((actions?.items.length ?? 0) <= 2, "at most two quick actions");
});

test("all-scope search: local sections precede the web block when something matches", () => {
	resetTabs();
	const output = computeResults(
		{
			parsed: parseInput("ash"),
			historyResults: [],
			searchSuggestions: ["ash tray", "ash ketchum"],
			searchEngine: "google",
		},
		0,
	);

	const ids = output.sections.map((s) => s.id);
	assert.ok(ids.indexOf("tabs") < ids.indexOf("search"), `tabs before search, got ${ids}`);
	assert.ok(ids.indexOf("search") < ids.indexOf("suggestions"), `search before suggestions, got ${ids}`);
	// Enter lands on the local match, not the web fallback.
	assert.equal(output.results[0]?.kind, "tab");
	assert.equal(output.results[0]?.title, "Ash Speed Test");
});

test("all-scope search: web block stays first when nothing local matches", () => {
	resetTabs();
	const output = computeResults(
		{
			parsed: parseInput("zzzz nothing"),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	assert.equal(output.sections[0]?.id, "search");
	assert.equal(output.results[0]?.kind, "search");
});

test("all-scope search: history section ranks after scored locals, before web", () => {
	resetTabs();
	const output = computeResults(
		{
			parsed: parseInput("ash"),
			historyResults: [historyResult("h1", "Ash history", "https://history.example/ash")],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	const ids = output.sections.map((s) => s.id);
	assert.ok(ids.indexOf("tabs") < ids.indexOf("history"), `tabs before history, got ${ids}`);
	assert.ok(ids.indexOf("history") < ids.indexOf("search"), `history before web, got ${ids}`);
});

test("all-scope search: a URL claimed by a tab no longer appears in history", () => {
	resetTabs();
	const output = computeResults(
		{
			parsed: parseInput("ash"),
			historyResults: [historyResult("h2", "Ash again", "https://ash-speed.example.com/")],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	const historySection = output.sections.find((s) => s.id === "history");
	assert.equal(historySection, undefined);
});

test("explicit tab scope keeps open tabs as the primary results", () => {
	resetTabs();

	const output = computeResults(
		{
			parsed: parseInput("@ ash"),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	assert.equal(output.sections[0]?.id, "tabs");
	assert.equal(output.results[0]?.kind, "tab");
});

test("> lists the typed command first, then shell completions without repeating it", () => {
	resetTabs();

	const output = computeResults(
		{
			parsed: parseInput(">git s"),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
			terminalCompletions: [
				{ command: "git status", source: "history" },
				{ command: "git s", source: "history" },
			],
		},
		0,
	);

	assert.deepEqual(output.sections.map((section) => section.id), ["terminal"]);
	assert.deepEqual(
		output.results.map((result) => [result.kind, result.payload.command]),
		[["terminal", "git s"], ["terminal", "git status"]],
	);
});

test("an empty > lists recent commands and nothing to run", () => {
	resetTabs();

	const output = computeResults(
		{
			parsed: parseInput(">"),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
			terminalCompletions: [{ command: "make test", source: "history" }],
		},
		0,
	);

	assert.deepEqual(output.results.map((result) => result.payload.command), ["make test"]);
});

test("all scope search query includes engine suggestions after the raw search", () => {
	resetTabs();

	// No local match for this query, so the web block leads and the
	// fallback/suggestions adjacency is observable at the top.
	const output = computeResults(
		{
			parsed: parseInput("plumbing tips"),
			historyResults: [],
			searchSuggestions: ["plumbing tips online", "plumbing tools"],
			searchEngine: "google",
		},
		0,
	);

	assert.equal(output.sections[0]?.id, "search");
	assert.equal(output.results[0]?.id, "search-fallback");
	assert.equal(output.results[1]?.id, "search-suggestion-0");
	assert.equal(output.results[1]?.title, "plumbing tips online");
	assert.equal(output.results[1]?.kind, "search");
});

test("engine suggestions are normalized without duplicate query entries", () => {
	assert.deepEqual(
		normalizeSearchSuggestions("ash", [
			"ash",
			" ash speed test ",
			"Ash Speed Test",
			"",
			"ash web",
		]),
		["ash speed test", "ash web"],
	);
});

test("known : command resolves to its deterministic action first", () => {
	resetTabs();

	const parsed = parseInput(": task manager");
	assert.equal(parsed.type, "action");
	assert.ok(parsed.action, "expected an exact command keyword match");

	const output = computeResults(
		{
			parsed,
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	assert.equal(output.sections[0]?.id, "actions");
	assert.equal(output.results[0]?.kind, "action");
});

test("url query matching an open tab offers Switch to Tab first", () => {
	resetTabs();
	const output = computeResults(
		{
			parsed: parseInput("ash-speed.example.com"),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	assert.equal(output.sections[0]?.id, "switch");
	assert.equal(output.results[0]?.kind, "tab");
	assert.equal(output.results[0]?.title, "Ash Speed Test");
	// Go To stays available right after.
	assert.equal(output.sections[1]?.id, "navigate");
});

test("url query with no matching open tab keeps Go To first", () => {
	resetTabs();
	const output = computeResults(
		{
			parsed: parseInput("nowhere.example"),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	assert.equal(output.sections[0]?.id, "navigate");
});

test("getLocalHostCompletion completes a host prefix from local urls", () => {
	const urls = [
		"https://www.example.com/lilo/pull/142",
		"https://docs.example.org/q/1",
		"file:///Users/me/notes.txt",
	];
	assert.equal(getLocalHostCompletion("exam", urls), "example.com");
	assert.equal(getLocalHostCompletion("docs", urls), "docs.example.org");
	assert.equal(getLocalHostCompletion("EXAM", urls), "example.com");
	// non-http(s) urls are skipped, no match gives ""
	assert.equal(getLocalHostCompletion("users", urls), "");
	assert.equal(getLocalHostCompletion("", urls), "");
	// already-complete host: nothing to add
	assert.equal(getLocalHostCompletion("example.com", urls), "");
});

test("computeResults follows the selected result id across a rebuild", () => {
	resetTabs();
	const params = {
		parsed: parseInput("ash"),
		historyResults: [] as CommandResult[],
		searchSuggestions: [] as string[],
		searchEngine: "google",
	};
	const first = computeResults(params, 0);
	const lastIndex = first.results.length - 1;
	const followedId = first.results[lastIndex]!.id;

	// Async data arrives and reorders/extends the list.
	const second = computeResults(
		{
			...params,
			historyResults: [historyResult("h4", "Ash elsewhere", "https://elsewhere.example/ash")],
			searchSuggestions: ["ash tray"],
		},
		lastIndex,
		followedId,
	);

	assert.equal(second.results[second.selectedIndex]?.id, followedId);
});

test("computeResults falls back to clamping when the pinned id vanished", () => {
	resetTabs();
	const output = computeResults(
		{
			parsed: parseInput("ash"),
			historyResults: [],
			searchSuggestions: [],
			searchEngine: "google",
		},
		99,
		"gone-result-id",
	);

	assert.equal(output.selectedIndex, output.results.length - 1);
});

test("all-scope search: flat order is pinned across fuzzy scores and score ties", () => {
	const initialState = {
		activeSpaceId: "space",
		activeTabId: "active-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: "space",
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs: [
			tab("active-tab", "Active", "https://active.example"),
			// Same title, same-length urls: an exact score tie broken by isPinned.
			tab("doc-late", "doc plain", "https://p1.example"),
			{ ...tab("doc-pinned", "doc plain", "https://p2.example"), isPinned: true },
			// Shorter haystack, higher score: must rank first.
			tab("doc-best", "doc", "https://d.example"),
		],
		treeItems: [],
		folders: [],
	};
	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);

	const output = computeResults(
		{
			parsed: parseInput("doc"),
			historyResults: [historyResult("h-doc", "doc history", "https://h.example/doc")],
			searchSuggestions: [],
			searchEngine: "google",
		},
		0,
	);

	assert.deepEqual(
		output.results.map((result) => result.id).slice(0, 4),
		["tab-doc-best", "tab-doc-pinned", "tab-doc-late", "h-doc"],
	);
});

test("all-scope search: an exact title match survives a long url and highlights verbatim", () => {
	const initialState = {
		activeSpaceId: "space",
		activeTabId: "active-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: "space", name: "Space", icon: "S", color: "#5865f2", profileId: "profile", isPrivate: false, sortOrder: 0 }],
		tabs: [
			tab("active-tab", "Active", "https://active.example"),
			tab("planning", "Q3 planning - Google Docs", "https://docs.google.com/document/d/1aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789/edit#heading=h.abcdef"),
			tab("gmail", "Gmail - Inbox (3)", "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJWDsKmBpLqRvNtZhGcWfTpLs"),
		],
		treeItems: [],
		folders: [],
	};
	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	const search = (query: string) => computeResults(
		{ parsed: parseInput(query), historyResults: [], searchSuggestions: [], searchEngine: "google", autofill: false },
		0,
	);

	const docs = search("docs");
	assert.equal(docs.results[0]?.id, "tab-planning");
	assert.deepEqual(docs.results[0]?.titleHighlights, [21, 22, 23, 24]);

	const inbox = search("inbox");
	assert.equal(inbox.results[0]?.id, "tab-gmail");
	assert.deepEqual(inbox.results[0]?.titleHighlights, [8, 9, 10, 11, 12]);
	assert.deepEqual(inbox.results[0]?.subtitleHighlights, []);
	resetTabs();
});

test("moving the tabs offers every edge but the current one", () => {
	resetTabs();

	const output = computeResults(
		{ parsed: parseInput("tabs top"), historyResults: [], searchSuggestions: [], searchEngine: "google" },
		0,
	);
	const ids = output.sections.flatMap((section) => section.items.map((item) => item.result.id));
	assert.ok(ids.some((id) => id.includes("moveTabsTop")), "the top edge is offered");

	const left = computeResults(
		{ parsed: parseInput("tabs left"), historyResults: [], searchSuggestions: [], searchEngine: "google" },
		0,
	);
	const leftIds = left.sections.flatMap((section) => section.items.map((item) => item.result.id));
	assert.ok(!leftIds.some((id) => id.includes("moveTabsLeft")), "the tabs are already on the left");
});
