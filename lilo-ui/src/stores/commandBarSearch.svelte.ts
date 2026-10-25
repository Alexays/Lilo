import { fuzzyMatch, fuzzySearch } from "../lib/fuzzySearch";
import { hostOf, normalizeURLForMatch } from "../lib/url";
import {
	COMMAND_ACTIONS,
	type CommandActionDefinition,
	type CommandScope,
	type ParsedInput,
	buildSearchURL,
	getSearchEngineLabel,
} from "../lib/inputParser";
import type {
	BridgeArchivedTab,
	BridgeClosedTerminal,
	BridgeSpaceSnapshot,
	BridgeTerminalCompletion,
	BridgeTerminalSummary,
} from "../lib/bridge/protocol";
import { formatAgo } from "./tabSwitcher.svelte";
import { formatTerminalDuration } from "../lib/terminalTitle";
import { getLocale, t } from "../lib/i18n/state.svelte";
import { getSetting } from "./settings.svelte";
import { shortcutKeys } from "./shortcutKeys.svelte";
import {
	getActiveTab,
	getBookmarkedTabs,
	getOpenTabs,
	tabDisplayTitle,
	type TabState,
} from "./tabs.svelte";
import { getFoldersById, getLockedFolderRoots } from "./folders.svelte";
import { getActiveSpaceId } from "./spaces.svelte";
import { getProfileById, getProfiles } from "./profiles.svelte";

export type ResultKind =
	| "tab"
	| "bookmark"
	| "history"
	| "action"
	| "navigate"
	| "search"
	| "omnibox"
	| "terminal"
	| "terminalTab"
	| "closedTerminal"
	| "archivedTab"
	| "clearArchive"
	| "lockedFolder"
	| "space"
	| "moveToSpace";

type CommandSectionID =
	| "navigate"
	| "switch"
	| "tabs"
	| "bookmarks"
	| "history"
	| "actions"
	| "suggestions"
	| "search"
	| "terminal"
	| "terminals"
	| "closedTerminals"
	| "archived"
	| "spaces";

export interface CommandResult {
	id: string;
	kind: ResultKind;
	title: string;
	subtitle?: string;
	icon?: string;
	url?: string;
	hint?: string;
	helper?: string;
	payload: Record<string, unknown>;
	titleHighlights?: number[];
	subtitleHighlights?: number[];
}

export interface CommandSectionEntry {
	index: number;
	result: CommandResult;
}

export interface CommandSection {
	id: CommandSectionID;
	title: string;
	subtitle?: string;
	items: CommandSectionEntry[];
}

interface CommandSectionDraft {
	id: CommandSectionID;
	title: string;
	subtitle?: string;
	items: CommandResult[];
	topScore: number;
}

type ResultOptions = Partial<
	Pick<CommandResult, "subtitle" | "icon" | "url" | "hint" | "helper" | "titleHighlights" | "subtitleHighlights">
>;

export type SearchableEntry = {
	id?: string | number;
	title?: string;
	url?: string;
	openedFrom?: string;
	visitCount?: number;
	lastVisitedAt?: number;
};
type ActionSearchEntry = {
	action: CommandActionDefinition;
	searchText: string;
	// " name keyword keyword", lowercased: a query matches a word's start when " " + query is in it.
	words: string;
};

const EMPTY_STATE_ACTIONS = new Set([
	"createTab",
	"createSpace",
	"openSettings",
	"openProcessManager",
	"toggleSidebar",
]);
export const HISTORY_SEARCH_DEBOUNCE_MS = 100;

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
// Fuzzy points per doubling of frecency: it reorders close matches, never lifts a poor one far.
const FRECENCY_WEIGHT = 3;

// Visits divided by one plus the weeks since the last one, the order native history search uses.
function frecencyBoost(visits: number, lastAt: number, now: number): number {
	return FRECENCY_WEIGHT * Math.log2(1 + visits / (1 + Math.max(0, now - lastAt) / WEEK_MS));
}

// Tab activations seen by this window: a tab is stamped when it becomes active and when it stops being.
const tabActivations = new Map<string, { count: number; at: number }>();
let lastActiveTabId = "";

export function noteActiveTab(tabId: string, now = Date.now()): void {
	if (tabId === lastActiveTabId) return;
	const previous = tabActivations.get(lastActiveTabId);
	if (previous) previous.at = now;
	lastActiveTabId = tabId;
	if (!tabId) return;
	const entry = tabActivations.get(tabId);
	if (entry) {
		entry.count += 1;
		entry.at = now;
	} else {
		tabActivations.set(tabId, { count: 1, at: now });
	}
}

// Set by computeResults: the history visits of the current query's candidates, by URL.
let rankNow = 0;
let historyVisitsByURL = new Map<string, { visitCount: number; lastVisitedAt: number }>();

// A tab ranks by its activations here, else by the history visits of its URL (bookmarks).
function tabFrecency(tab: TabState): number {
	const activation = tabActivations.get(tab.id);
	if (activation) return frecencyBoost(activation.count, activation.at, rankNow);
	const visits = historyVisitsByURL.get(tab.url);
	return visits ? frecencyBoost(visits.visitCount, visits.lastVisitedAt, rankNow) : 0;
}

// The localized name and description match alongside the English keywords; the name leads
// the haystack so its highlights map onto the title. Rebuilt only when its inputs change.
let actionIndexCache:
	| { locale: string; terminalEnabled: boolean; entries: ActionSearchEntry[] }
	| undefined;

function actionSearchIndex(): ActionSearchEntry[] {
	const terminalEnabled = getSetting("terminalEnabled", "true") !== "false";
	const locale = getLocale();
	if (actionIndexCache?.locale === locale && actionIndexCache.terminalEnabled === terminalEnabled) {
		return actionIndexCache.entries;
	}
	const entries = COMMAND_ACTIONS.filter((action) => terminalEnabled || (action.id !== "newTerminal" && action.id !== "nextWaitingTerminal")).map((action) => ({
		action,
		searchText: [t(action.nameKey), t(action.descriptionKey), ...action.keywords]
			.join(" ")
			.toLowerCase(),
		words: ` ${[t(action.nameKey), ...action.keywords].join(" ").toLowerCase()}`,
	}));
	actionIndexCache = { locale, terminalEnabled, entries };
	return entries;
}

// Lowercased "title url" haystack per tab snapshot. Snapshots are replaced, never
// mutated, on every bridge patch, so keying by identity only needs a reset when the
// locale changes the blank tab's displayed title.
let tabHaystacks = new WeakMap<TabState, string>();
let tabHaystacksLocale = getLocale();

function tabHaystack(tab: TabState): string {
	if (tabHaystacksLocale !== getLocale()) {
		tabHaystacks = new WeakMap();
		tabHaystacksLocale = getLocale();
	}
	let haystack = tabHaystacks.get(tab);
	if (haystack === undefined) {
		haystack = `${tab.customTitle || tabDisplayTitle(tab.title)} ${tab.url}`.toLowerCase();
		tabHaystacks.set(tab, haystack);
	}
	return haystack;
}

// normalizeURLForMatch(tab.url) per tab snapshot, same identity keying as tabHaystacks.
const tabMatchURLs = new WeakMap<TabState, string>();

function splitHighlights(
	highlights: number[],
	titleLength: number,
): { titleHighlights: number[]; subtitleHighlights: number[] } {
	return {
		titleHighlights: highlights.filter((i) => i < titleLength),
		subtitleHighlights: highlights
			.filter((i) => i > titleLength)
			.map((i) => i - titleLength - 1),
	};
}

function createResult(
	id: string,
	kind: ResultKind,
	title: string,
	payload: Record<string, unknown> = {},
	options: ResultOptions = {},
): CommandResult {
	return {
		id,
		kind,
		title,
		payload,
		...options,
	};
}

function toTabResult(tab: TabState, highlights?: number[]): CommandResult {
	const title = tab.customTitle || tabDisplayTitle(tab.title);
	const { titleHighlights, subtitleHighlights } = highlights
		? splitHighlights(highlights, title.length)
		: { titleHighlights: undefined, subtitleHighlights: undefined };
	return createResult(
		`tab-${tab.id}`,
		"tab",
		title,
		{ tabId: tab.id },
		{ subtitle: tab.url, icon: "T", hint: t("commandBar.hintSwitch"), url: tab.url, titleHighlights, subtitleHighlights },
	);
}

function toBookmarkResult(tab: TabState, highlights?: number[]): CommandResult {
	const title = tab.customTitle || tabDisplayTitle(tab.title);
	const { titleHighlights, subtitleHighlights } = highlights
		? splitHighlights(highlights, title.length)
		: { titleHighlights: undefined, subtitleHighlights: undefined };
	return createResult(
		`bookmark-${tab.id}`,
		"bookmark",
		title,
		{ tabId: tab.id },
		{ subtitle: tab.url, icon: "B", hint: t("commandBar.hintOpen"), url: tab.url, titleHighlights, subtitleHighlights },
	);
}

function toActionResult(action: CommandActionDefinition, highlights?: number[]): CommandResult {
	const name = t(action.nameKey);
	return createResult(
		`action-${action.id}`,
		"action",
		name,
		{ action: action.id },
		{
			subtitle: t(action.descriptionKey),
			icon: action.icon,
			hint: t("commandBar.hintRun"),
			helper: action.shortcutId && shortcutKeys(action.shortcutId),
			titleHighlights: highlights?.filter((i) => i < name.length),
		},
	);
}

// With a query, rows rank by their best fuzzy field plus frecency; without one, in host order (newest first).
export function toHistoryResults(items: SearchableEntry[], query?: string, now = Date.now()): CommandResult[] {
	const lowerQuery = query ? query.toLowerCase() : undefined;
	const scores = new Map<CommandResult, number>();
	const results = items.map((item, index) => {
		const titleMatch = lowerQuery ? fuzzyMatch(lowerQuery, (item.title || "").toLowerCase()) : null;
		const urlMatch = lowerQuery ? fuzzyMatch(lowerQuery, (item.url || "").toLowerCase()) : null;
		const visitCount = item.visitCount ?? 0;
		const lastVisitedAt = item.lastVisitedAt ?? 0;
		const result = createResult(
			`history-${item.id || index}`,
			"history",
			item.title || "",
			{ visitCount, lastVisitedAt },
			{
				subtitle: item.url || "",
				helper: item.openedFrom ? t("commandBar.historyFromTerminal", { terminal: item.openedFrom }) : undefined,
				icon: "H",
				hint: t("commandBar.hintOpen"),
				url: item.url || "",
				titleHighlights: titleMatch?.highlights,
				subtitleHighlights: urlMatch?.highlights,
			},
		);
		if (lowerQuery) {
			// Rows FTS found but the in-order match misses (reordered words) rank after every match, by frecency.
			const match = titleMatch || urlMatch ? Math.max(titleMatch?.score ?? -Infinity, urlMatch?.score ?? -Infinity) : -1e6;
			scores.set(result, match + frecencyBoost(visitCount, lastVisitedAt, now));
		}
		return result;
	});
	if (lowerQuery) results.sort((a, b) => scores.get(b)! - scores.get(a)!);
	return results;
}

function uniqueByURL(
	items: CommandResult[],
	urls: Set<string>,
	limit = items.length,
): CommandResult[] {
	const unique: CommandResult[] = [];

	for (const item of items) {
		if (item.url && urls.has(item.url)) continue;
		if (item.url) urls.add(item.url);
		unique.push(item);
		if (unique.length >= limit) break;
	}

	return unique;
}

// Returns a comparator that reads the active tab id once, not once per comparison.
function activeTabFirstSort(
	activeTabId = getActiveTab()?.id ?? "",
): (lhs: TabState, rhs: TabState) => number {
	return (lhs, rhs) => {
		if (lhs.id === activeTabId) return -1;
		if (rhs.id === activeTabId) return 1;
		if (lhs.isPinned !== rhs.isPinned) return lhs.isPinned ? -1 : 1;
		if (lhs.isClosed !== rhs.isClosed) return lhs.isClosed ? 1 : -1;
		return 0;
	};
}

function getInactiveOpenTabs(locked = getLockedFolderRoots()): TabState[] {
	const activeTabId = getActiveTab()?.id ?? "";
	return getOpenTabs().filter((tab) => tab.id !== activeTabId && !(tab.groupId && locked.has(tab.groupId)));
}

// A URL after its scheme and a leading "www.", lowercased.
function addressOf(url = ""): string {
	return url.toLowerCase().replace(/^[a-z][a-z0-9+.-]*:\/\/(www\.)?/, "");
}

function tabMatchURL(tab: TabState): string {
	let url = tabMatchURLs.get(tab);
	if (url === undefined) {
		url = normalizeURLForMatch(tab.url);
		tabMatchURLs.set(tab, url);
	}
	return url;
}

// A history row for a page open in another tab switches to that tab rather than opening it twice.
// It keeps its text and highlights, and takes the tab's URL so the tab's own row dedupes against it.
function switchToOpenTabs(history: CommandResult[], tabs: TabState[]): CommandResult[] {
	if (history.length === 0 || tabs.length === 0) return history;
	const tabsByURL = new Map<string, TabState>();
	for (const tab of tabs) {
		const url = tabMatchURL(tab);
		if (!tabsByURL.has(url)) tabsByURL.set(url, tab);
	}
	return history.map((result): CommandResult => {
		const tab = result.url ? tabsByURL.get(normalizeURLForMatch(result.url)) : undefined;
		return tab
			? { ...result, id: `tab-${tab.id}`, kind: "tab", payload: { tabId: tab.id }, url: tab.url, hint: t("commandBar.hintSwitch") }
			: result;
	});
}

/** One row per locked folder holding a match, never naming the matching tab. */
function getLockedFolderResults(query: string, locked = getLockedFolderRoots()): CommandResult[] {
	const needle = query.trim().toLowerCase();
	if (!needle) return [];
	if (locked.size === 0) return [];
	const folders = getFoldersById();
	const matched = new Set<string>();
	for (const tab of getOpenTabs()) {
		const rootId = tab.groupId ? locked.get(tab.groupId) : undefined;
		if (rootId && !matched.has(rootId) && fuzzyMatch(needle, tabHaystack(tab))) matched.add(rootId);
	}
	return [...matched].map((folderId) => {
		const name = folders.get(folderId)?.name ?? "";
		return createResult(`locked-${folderId}`, "lockedFolder", t("commandBar.lockedFolderResults", { name }), { folderId }, {
			icon: name.charAt(0).toUpperCase(),
			hint: t("tabFolder.unlock"),
		});
	});
}

function fuzzyTabResults(
	source: TabState[],
	mapper: (tab: TabState, highlights?: number[]) => CommandResult,
	query: string,
	limit: number,
	minScore = -Infinity,
): { results: CommandResult[]; topScore: number } {
	const matches = fuzzySearch<TabState>(
		source,
		query,
		tabHaystack,
		limit,
		minScore,
		activeTabFirstSort(),
		(tab) => (tab.customTitle || tabDisplayTitle(tab.title)).length,
		tabFrecency,
	);
	return {
		results: matches.map(({ data, highlights }) => mapper(data, highlights)),
		topScore: matches[0]?.score ?? -Infinity,
	};
}

function getOpenTabResults(
	query: string,
	limit: number,
	minScore = -Infinity,
	source = getInactiveOpenTabs(),
): { results: CommandResult[], topScore: number } {
	return fuzzyTabResults(source, toTabResult, query, limit, minScore);
}

function getBookmarkResults(query: string, limit: number, minScore = -Infinity): { results: CommandResult[], topScore: number } {
	return fuzzyTabResults(getBookmarkedTabs(), toBookmarkResult, query, limit, minScore);
}

// With `wordStart`, only actions where the query starts a word of their name or keywords.
function getActionResults(query: string, limit: number, wordStart = false): CommandResult[] {
	const needle = ` ${query.trim().toLowerCase()}`;
	const index = actionSearchIndex();
	return fuzzySearch(
		wordStart ? index.filter((entry) => entry.words.includes(needle)) : index,
		query,
		(entry) => entry.searchText,
		limit,
	).map(({ data, highlights }) => toActionResult(data.action, highlights));
}

type SpaceRow = { kind: "space" | "moveToSpace"; titleKey?: string };

// One row per kind and Space other than the active one (never another window's private Space). A row
// matches on its title, then its Space's profile, shown as the subtitle once there are several profiles.
function spaceResults(
	spaces: BridgeSpaceSnapshot[],
	query: string,
	rows: SpaceRow[],
	limit: number,
	minScore = -Infinity,
	tabId?: string,
): { results: CommandResult[]; topScore: number } {
	const activeSpaceId = getActiveSpaceId();
	const showProfile = getProfiles().length > 1;
	const entries: { row: SpaceRow; space: BridgeSpaceSnapshot; title: string; profile: string; haystack: string }[] = [];
	for (const row of rows) {
		for (const space of spaces) {
			if (space.id === activeSpaceId || space.isPrivate) continue;
			const title = row.titleKey ? t(row.titleKey, { name: space.name }) : space.name;
			const profile = showProfile ? (getProfileById(space.profileId)?.name ?? "") : "";
			entries.push({ row, space, title, profile, haystack: `${title} ${profile}`.toLowerCase() });
		}
	}
	const matches = query.trim()
		? fuzzySearch(entries, query, (entry) => entry.haystack, limit, minScore, undefined, (entry) => entry.title.length)
		: entries.slice(0, limit).map((data) => ({ data, score: 0, highlights: [] as number[] }));
	return {
		results: matches.map(({ data, highlights }) => createResult(
			`${data.row.kind}-${data.space.id}`,
			data.row.kind,
			data.title,
			{ spaceId: data.space.id, tabId },
			{
				subtitle: data.profile || undefined,
				icon: data.space.icon || "🌐",
				hint: t(data.row.kind === "space" ? "commandBar.hintSwitch" : "commandBar.hintMove"),
				...splitHighlights(highlights, data.title.length),
			},
		)),
		topScore: matches[0]?.score ?? -Infinity,
	};
}

function makeFallbackResult(
	parsed: ParsedInput,
	searchEngine: string,
): CommandResult | undefined {
	if (parsed.type === "url") {
		return createResult(
			"go-url",
			"navigate",
			t("commandBar.openUrl", { url: parsed.url ?? "" }),
			{ typed: true },
			{
				subtitle: parsed.url,
				icon: ">",
				hint: t("commandBar.hintGo"),
				url: parsed.url,
			},
		);
	}

	if (parsed.type === "search" && parsed.query) {
		return createResult(
			"search-fallback",
			"search",
			t("commandBar.searchFor", { query: parsed.query }),
			{},
			{
				subtitle: getSearchEngineLabel(searchEngine),
				icon: "?",
				hint: t("commandBar.hintSearch"),
				url: buildSearchURL(parsed.query, searchEngine),
			},
		);
	}
}

export function normalizeSearchSuggestions(
	query: string,
	suggestions: string[],
	limit = 5,
): string[] {
	const trimmedQuery = query.trim().toLowerCase();
	const seen = new Set<string>(trimmedQuery ? [trimmedQuery] : []);
	const normalized: string[] = [];

	for (const suggestion of suggestions) {
		const value = suggestion.trim().replace(/\s+/g, " ");
		const key = value.toLowerCase();
		if (!value || seen.has(key)) continue;
		seen.add(key);
		normalized.push(value);
		if (normalized.length >= limit) break;
	}

	return normalized;
}

export function getLocalHostCompletion(
	query: string,
	urls: string[],
): string {
	const trimmed = query.trim().toLowerCase();
	if (!trimmed) return "";
	for (const url of urls) {
		if (!/^https?:\/\//i.test(url)) continue;
		const host = hostOf(url);
		if (host && host.startsWith(trimmed) && host.length > trimmed.length) return host;
	}
	return "";
}

// The site a typed host prefix completes to, Firefox's origin autofill: the most visited host
// the query starts, found in an open tab, a bookmark or at least twice in history.
function autofillResult(query: string, history: CommandResult[], tabs: TabState[]): CommandResult | undefined {
	if (!/^[a-z0-9][a-z0-9.-]*$/.test(query)) return undefined;
	const visits = new Map<string, number>();
	const origins = new Map<string, string>();
	const note = (url: string | undefined, count: number) => {
		if (!url || !/^https?:\/\//i.test(url)) return;
		const host = hostOf(url);
		if (!host?.startsWith(query) || host.length === query.length) return;
		if (!origins.has(host)) origins.set(host, `${new URL(url).origin}/`);
		visits.set(host, (visits.get(host) ?? 0) + count);
	};
	for (const tab of tabs) note(tab.url, 2);
	for (const tab of getBookmarkedTabs()) note(tab.url, 2);
	for (const row of history) note(row.url, (row.payload.visitCount as number) || 1);

	let host = "";
	for (const [candidate, count] of visits) {
		if (count >= 2 && count > (visits.get(host) ?? 0)) host = candidate;
	}
	if (!host) return undefined;
	const origin = origins.get(host)!;
	const target = normalizeURLForMatch(origin);
	const openTab = tabs.find((tab) => tabMatchURL(tab) === target);
	if (openTab) return toTabResult(openTab);
	return createResult("autofill", "navigate", host, { typed: false }, {
		subtitle: origin,
		icon: ">",
		hint: t("commandBar.hintGo"),
		url: origin,
		titleHighlights: Array.from(query, (_, index) => index),
	});
}

function searchSuggestionResults(
	query: string,
	suggestions: string[],
	searchEngine: string,
): CommandResult[] {
	return normalizeSearchSuggestions(query, suggestions).map((suggestion, index) =>
		createResult(
			`search-suggestion-${index}`,
			"search",
			suggestion,
			{ suggestion },
			{
				subtitle: getSearchEngineLabel(searchEngine),
				icon: "?",
				hint: t("commandBar.hintSearch"),
				url: buildSearchURL(suggestion, searchEngine),
			},
		),
	);
}

function emptyStateTabResults(limit: number): CommandResult[] {
	const order = activeTabFirstSort();
	return [...getInactiveOpenTabs()]
		.sort((lhs, rhs) => order(lhs, rhs) || tabFrecency(rhs) - tabFrecency(lhs))
		.slice(0, limit)
		.map((tab) => toTabResult(tab));
}

function emptyStateBookmarkResults(limit: number): CommandResult[] {
	return [...getBookmarkedTabs()]
		.sort(activeTabFirstSort())
		.slice(0, limit)
		.map((tab) => toBookmarkResult(tab));
}

function emptyStateActionResults(limit: number): CommandResult[] {
	return COMMAND_ACTIONS.filter((action) => EMPTY_STATE_ACTIONS.has(action.id))
		.slice(0, limit)
		.map((action) => toActionResult(action));
}

function addSection(
	sections: CommandSectionDraft[],
	id: CommandSectionID,
	title: string,
	items: CommandResult[],
	subtitle?: string,
	topScore = -Infinity,
): void {
	if (items.length === 0) return;
	sections.push({ id, title, subtitle, items, topScore });
}

function buildEmptySections(
	scope: CommandScope,
	historyResults: CommandResult[],
): CommandSectionDraft[] {
	const sections: CommandSectionDraft[] = [];

	if (scope === "action") {
		addSection(
			sections,
			"actions",
			t("commandBar.sectionQuickActions"),
			emptyStateActionResults(6),
		);
		return sections;
	}

	if (scope === "tab") {
		addSection(sections, "tabs", t("commandBar.sectionOpenTabs"), emptyStateTabResults(8));
		return sections;
	}

	if (scope === "bookmark") {
		addSection(
			sections,
			"bookmarks",
			t("commandBar.sectionBookmarks"),
			uniqueByURL(emptyStateBookmarkResults(8), new Set()),
			t("commandBar.subtitleCurrentSpace"),
		);
		return sections;
	}

	if (scope === "history") {
		addSection(
			sections,
			"history",
			t("commandBar.sectionRecentHistory"),
			uniqueByURL(historyResults, new Set(), 8),
			t("commandBar.subtitleLatestVisits"),
		);
		return sections;
	}

	const seenURLs = new Set<string>();
	addSection(
		sections,
		"history",
		t("commandBar.sectionRecentHistory"),
		uniqueByURL(switchToOpenTabs(historyResults, getInactiveOpenTabs()), seenURLs, 8),
		t("commandBar.subtitleContinue"),
	);
	addSection(
		sections,
		"tabs",
		t("commandBar.sectionOpenTabs"),
		uniqueByURL(emptyStateTabResults(5), seenURLs),
		t("commandBar.subtitleCurrentSpace"),
	);
	addSection(
		sections,
		"bookmarks",
		t("commandBar.sectionBookmarks"),
		uniqueByURL(emptyStateBookmarkResults(4), seenURLs),
		t("commandBar.subtitleCurrentSpace"),
	);
	addSection(
		sections,
		"actions",
		t("commandBar.sectionQuickActions"),
		emptyStateActionResults(2),
		t("commandBar.subtitleCommonCommands"),
	);

	return sections;
}

// Who needs the user first: waiting for an answer (longest first), working, failed, the rest.
function terminalUrgency(terminal: BridgeTerminalSummary): number {
	if (terminal.awaitingInputSince) return 0;
	if (terminal.state === "busy" || terminal.state === "waiting") return 1;
	return terminal.state === "failed" ? 2 : 3;
}

function terminalStatusLine(terminal: BridgeTerminalSummary, now: number): string {
	const since = (start: number) => formatTerminalDuration((now - start) / 1000);
	if (terminal.awaitingInputSince) return `${t("tabItem.terminalAttention")} · ${since(terminal.awaitingInputSince)}`;
	if (terminal.state === "busy" || terminal.state === "waiting") {
		const label = t(terminal.state === "busy" ? "tabItem.terminalBusy" : "tabItem.terminalWaiting");
		return terminal.startedAt ? `${label} · ${since(terminal.startedAt)}` : label;
	}
	const took = formatTerminalDuration(terminal.duration);
	if (terminal.state === "failed") return `${t("commandBar.terminalFailedCode", { code: String(terminal.exitCode) })} · ${took}`;
	if (terminal.state === "succeeded") return `${t("tabItem.terminalSucceeded")} · ${took}`;
	return t(terminal.state === "exited" ? "commandBar.terminalExited" : "commandBar.terminalAtPrompt");
}

function terminalTabResults(query: string, terminals: BridgeTerminalSummary[]): CommandResult[] {
	const needle = query.toLowerCase();
	const now = Date.now();
	return terminals
		.filter((terminal) => !needle || [terminal.title, terminal.command, terminal.gitBranch, terminal.spaceName]
			.some((field) => field.toLowerCase().includes(needle)))
		.sort((a, b) => terminalUrgency(a) - terminalUrgency(b) || (a.awaitingInputSince - b.awaitingInputSince))
		.map((terminal) => createResult(`terminal-tab:${terminal.tabId}`, "terminalTab", terminal.title, { tabId: terminal.tabId }, {
			subtitle: terminalStatusLine(terminal, now),
			helper: [terminal.spaceName, terminal.gitBranch].filter(Boolean).join(" · "),
			icon: "terminal",
			hint: t("commandBar.hintSwitch"),
		}));
}

function closedTerminalResults(query: string, closed: BridgeClosedTerminal[]): CommandResult[] {
	const needle = query.toLowerCase();
	const now = Date.now();
	return closed
		.filter((terminal) => !needle || [terminal.title, terminal.resumeCommand, terminal.gitBranch, terminal.folder]
			.some((field) => field.toLowerCase().includes(needle)))
		.map((terminal) => createResult(`closed-terminal:${terminal.index}`, "closedTerminal", terminal.title || terminal.folder, { index: terminal.index }, {
			subtitle: [
				t("commandBar.closedAgo", { when: formatAgo(now - terminal.closedAt) }),
				terminal.resumeCommand,
			].filter(Boolean).join(" · "),
			helper: [terminal.spaceName, terminal.folder, terminal.gitBranch].filter(Boolean).join(" · "),
			icon: "terminal",
			hint: t("commandBar.hintReopen"),
		}));
}

function buildTerminalSections(
	query: string,
	completions: BridgeTerminalCompletion[],
	terminals: BridgeTerminalSummary[],
	closed: BridgeClosedTerminal[],
): CommandSectionDraft[] {
	const run = query
		? [createResult(`terminal-run:${query}`, "terminal", query, { command: query }, {
			subtitle: t("commandBar.terminalRun"),
			icon: "prompt",
			hint: t("commandBar.hintRun"),
		})]
		: [];
	const suggestions = completions
		.filter((item) => item.command !== query)
		.map((item) => createResult(`terminal:${item.command}`, "terminal", item.command, { command: item.command }, {
			subtitle: t(item.source === "history" ? "commandBar.terminalFromHistory" : "commandBar.terminalProgram"),
			icon: item.source === "history" ? "history" : "prompt",
			hint: t("commandBar.hintRun"),
		}));
	const sections: CommandSectionDraft[] = [];
	const open = terminalTabResults(query, terminals);
	// Typed text is a command first: Enter keeps running it, the matching terminals come after.
	if (!query) addSection(sections, "terminals", t("commandBar.sectionTerminals"), open);
	addSection(sections, "terminal", t("commandBar.sectionTerminal"), [...run, ...suggestions]);
	if (query) addSection(sections, "terminals", t("commandBar.sectionTerminals"), open);
	addSection(sections, "closedTerminals", t("commandBar.sectionClosedTerminals"), closedTerminalResults(query, closed));
	return sections;
}

// "3 hours ago", in the chrome's language, at the largest unit that fits.
function timeAgo(timestamp: number, now: number, format: Intl.RelativeTimeFormat): string {
	const minutes = Math.round((timestamp - now) / 60_000);
	if (Math.abs(minutes) < 60) return format.format(minutes, "minute");
	if (Math.abs(minutes) < 24 * 60) return format.format(Math.round(minutes / 60), "hour");
	return format.format(Math.round(minutes / (24 * 60)), "day");
}

function buildArchiveSections(query: string, archived: BridgeArchivedTab[]): CommandSectionDraft[] {
	const needle = query.toLowerCase();
	const now = Date.now();
	// One formatter for every row: an Intl formatter is costly to build.
	const format = new Intl.RelativeTimeFormat(getLocale(), { numeric: "auto" });
	const results = archived
		.filter((tab) => !needle || `${tab.title} ${tab.url}`.toLowerCase().includes(needle))
		.map((tab) => createResult(`archived:${tab.id}`, "archivedTab", tab.title || tab.url, { id: tab.id }, {
			subtitle: t("commandBar.archivedAgo", { when: timeAgo(tab.archivedAt, now, format) }),
			helper: hostOf(tab.url) ?? undefined,
			url: tab.url,
			hint: t("commandBar.hintReopen"),
		}));
	// Clearing empties the whole archive, so it is offered only over the whole list.
	if (!needle && results.length > 0) {
		results.push(createResult("archive-clear", "clearArchive", t("commandBar.clearArchive"), {}, {
			icon: "trash",
			hint: t("commandBar.hintRun"),
		}));
	}
	const sections: CommandSectionDraft[] = [];
	addSection(sections, "archived", t("commandBar.sectionArchivedTabs"), results, t("commandBar.subtitleCurrentSpace"));
	return sections;
}

function buildScopedSections(
	scope: Exclude<CommandScope, "all" | "archive">,
	query: string,
	historyResults: CommandResult[],
	spaces: BridgeSpaceSnapshot[],
): CommandSectionDraft[] {
	const seenURLs = new Set<string>();
	const sections: CommandSectionDraft[] = [];

	switch (scope) {
		case "action": {
			addSection(sections, "actions", t("commandBar.sectionActions"), getActionResults(query, 8));
			const rows: SpaceRow[] = [{ kind: "space", titleKey: "commandBar.switchToSpace" }];
			if (getActiveTab()) rows.push({ kind: "moveToSpace", titleKey: "commandBar.moveTabToSpace" });
			addSection(sections, "spaces", t("commandBar.sectionSpaces"), spaceResults(spaces, query, rows, 6).results);
			break;
		}
		case "tab":
			addSection(
				sections,
				"tabs",
				t("commandBar.sectionOpenTabs"),
				[...uniqueByURL(getOpenTabResults(query, 8).results, seenURLs), ...getLockedFolderResults(query)],
			);
			break;
		case "bookmark":
			addSection(
				sections,
				"bookmarks",
				t("commandBar.sectionBookmarks"),
				uniqueByURL(getBookmarkResults(query, 8).results, seenURLs),
				t("commandBar.subtitleCurrentSpace"),
			);
			break;
		case "history":
			addSection(
				sections,
				"history",
				t("commandBar.sectionHistory"),
				uniqueByURL(historyResults, seenURLs, 8),
			);
			break;
	}

	return sections;
}

function buildAllSections(
	parsed: ParsedInput,
	historyResults: CommandResult[],
	searchSuggestions: string[],
	searchEngine: string,
	spaces: BridgeSpaceSnapshot[],
	autofill: boolean,
): CommandSectionDraft[] {
	const seenURLs = new Set<string>();
	const sections: CommandSectionDraft[] = [];
	const actionResults = getActionResults(parsed.query, 4, true);
	const fallback = makeFallbackResult(parsed, searchEngine);
	const locked = getLockedFolderRoots();
	const inactiveTabs = getInactiveOpenTabs(locked);
	const autofillRow = autofill && parsed.type !== "action"
		? autofillResult(parsed.query.toLowerCase(), historyResults, inactiveTabs)
		: undefined;
	if (autofillRow?.url) seenURLs.add(autofillRow.url);

	if (parsed.type === "url" && fallback) {
		const target = normalizeURLForMatch(parsed.url ?? "");
		const openMatch = inactiveTabs.find((tab) => tabMatchURL(tab) === target);
		if (openMatch) {
			addSection(
				sections,
				"switch",
				t("commandBar.sectionSwitchToTab"),
				uniqueByURL([toTabResult(openMatch)], seenURLs),
			);
		}
		addSection(
			sections,
			"navigate",
			t("commandBar.sectionGoTo"),
			autofillRow ? [autofillRow, fallback] : [fallback],
			t("commandBar.subtitleDirectNavigation"),
		);
	} else if (autofillRow) {
		addSection(sections, "navigate", t("commandBar.sectionGoTo"), [autofillRow]);
	}

	if (parsed.type === "action") {
		const { results: tabItems } = getOpenTabResults(parsed.query, 5, -Infinity, inactiveTabs);
		const { results: bookmarkItems } = getBookmarkResults(parsed.query, 4);
		addSection(sections, "actions", t("commandBar.sectionActions"), actionResults, t("commandBar.subtitleExactCommand"));
		addSection(sections, "tabs", t("commandBar.sectionOpenTabs"), uniqueByURL(tabItems, seenURLs));
		addSection(sections, "bookmarks", t("commandBar.sectionBookmarks"), uniqueByURL(bookmarkItems, seenURLs), t("commandBar.subtitleCurrentSpace"));
		addSection(sections, "history", t("commandBar.sectionHistory"), uniqueByURL(switchToOpenTabs(historyResults, inactiveTabs), seenURLs, 8));
		return sections;
	}

	// Local results claim URLs (and the top slot) before the web block: the bar
	// is a switcher first, a search box second.
	const { results: tabItems, topScore: tabScore } = getOpenTabResults(parsed.query, 5, 0, inactiveTabs);
	const { results: bookmarkItems, topScore: bookmarkScore } = getBookmarkResults(parsed.query, 4, 0);
	const tabResults = uniqueByURL(tabItems, seenURLs);
	const bookmarkResults = uniqueByURL(bookmarkItems, seenURLs);
	const historyFiltered = uniqueByURL(switchToOpenTabs(historyResults, inactiveTabs), seenURLs, 8);
	// Rows the host's full-text search found but the typed text does not match in order (words apart,
	// reordered) never take the top slot from the web search. Matched rows sort first.
	const topHistory = historyFiltered[0];
	const lowerQuery = parsed.query.toLowerCase();
	const historyMatches = !!topHistory && !!(
		fuzzyMatch(lowerQuery, topHistory.title.toLowerCase()) || fuzzyMatch(lowerQuery, (topHistory.url ?? "").toLowerCase())
	);

	const localSections: CommandSectionDraft[] = [];
	const lockedResults = getLockedFolderResults(parsed.query, locked);
	const { results: spaceItems, topScore: spaceScore } = spaceResults(spaces, parsed.query, [{ kind: "space" }], 3, 0);
	addSection(localSections, "tabs", t("commandBar.sectionOpenTabs"), [...tabResults, ...lockedResults], undefined, tabScore);
	addSection(localSections, "spaces", t("commandBar.sectionSpaces"), spaceItems, undefined, spaceScore);
	addSection(localSections, "bookmarks", t("commandBar.sectionBookmarks"), bookmarkResults, t("commandBar.subtitleCurrentSpace"), bookmarkScore);
	if (historyMatches || parsed.type !== "search") addSection(localSections, "history", t("commandBar.sectionHistory"), historyFiltered);
	// Stable sort: scored sections by score, unscored (history, -Infinity) keep
	// their position after them.
	localSections.sort((a, b) => b.topScore - a.topScore);
	// History whose top address starts with the query (a site being typed) goes ahead of every
	// section whose top row the query only fuzzy-matches; a row it starts as well keeps the lead.
	if (historyMatches && addressOf(topHistory?.url).startsWith(lowerQuery)) {
		const historyIndex = localSections.findIndex((section) => section.id === "history");
		const lead = localSections.findIndex((section) => {
			const top = section.items[0];
			return section.id !== "history" && !top?.title.toLowerCase().startsWith(lowerQuery) && !addressOf(top?.url).startsWith(lowerQuery);
		});
		if (lead >= 0 && lead < historyIndex) localSections.splice(lead, 0, ...localSections.splice(historyIndex, 1));
	}

	const webSections: CommandSectionDraft[] = [];
	if (parsed.type === "search" && fallback) {
		addSection(webSections, "search", t("commandBar.sectionSearchWeb"), [fallback], t("commandBar.subtitleDefaultEngine"));
		addSection(
			webSections,
			"suggestions",
			t("commandBar.sectionSuggestions"),
			searchSuggestionResults(parsed.query, searchSuggestions, searchEngine),
		);
	}

	sections.push(...localSections, ...webSections);
	if (!historyMatches && parsed.type === "search") addSection(sections, "history", t("commandBar.sectionHistory"), historyFiltered);

	addSection(sections, "actions", t("commandBar.sectionActions"), actionResults);

	return sections;
}

interface ComputeResultsParams {
	parsed: ParsedInput;
	historyResults: CommandResult[];
	searchSuggestions: string[];
	searchEngine: string;
	terminalCompletions?: BridgeTerminalCompletion[];
	terminals?: BridgeTerminalSummary[];
	closedTerminals?: BridgeClosedTerminal[];
	archivedTabs?: BridgeArchivedTab[];
	/** The Spaces a switch or a move can target, in sidebar order. */
	spaces?: BridgeSpaceSnapshot[];
	/** A tab being moved: the bar lists the Spaces it can go to instead. */
	moveTabId?: string;
	/** False right after a deletion: the bar then completes no host, so the typed text stays what Enter opens. */
	autofill?: boolean;
	/// When an extension omnibox keyword is active, its suggestions replace the normal sections.
	omnibox?: { active: boolean; title: string; results: CommandResult[] };
}

interface ComputeResultsOutput {
	results: CommandResult[];
	sections: CommandSection[];
	selectedIndex: number;
	activeScope: CommandScope;
}

export function computeResults(
	params: ComputeResultsParams,
	currentSelectedIndex: number,
	currentSelectedId?: string,
): ComputeResultsOutput {
	const { parsed, historyResults, searchSuggestions, searchEngine } = params;
	rankNow = Date.now();
	historyVisitsByURL = new Map();
	for (const result of historyResults) {
		if (result.url) historyVisitsByURL.set(result.url, result.payload as { visitCount: number; lastVisitedAt: number });
	}

	let sectionDrafts: CommandSectionDraft[];

	if (params.moveTabId) {
		sectionDrafts = [];
		const { results } = spaceResults(params.spaces ?? [], parsed.query, [{ kind: "moveToSpace" }], 20, -Infinity, params.moveTabId);
		addSection(sectionDrafts, "spaces", t("commandBar.sectionMoveTab"), results);
	} else if (params.omnibox?.active) {
		// Extension omnibox keyword session: show only the extension's suggestions.
		sectionDrafts = params.omnibox.results.length
			? [{ id: "suggestions", title: params.omnibox.title, items: params.omnibox.results, topScore: 1 }]
			: [];
	} else if (parsed.scope === "terminal") {
		sectionDrafts = buildTerminalSections(
			parsed.query, params.terminalCompletions ?? [], params.terminals ?? [], params.closedTerminals ?? [],
		);
	} else if (parsed.scope === "archive") {
		sectionDrafts = buildArchiveSections(parsed.query, params.archivedTabs ?? []);
	} else if (!parsed.query) {
		sectionDrafts = buildEmptySections(parsed.scope, historyResults);
	} else if (parsed.scope === "all") {
		sectionDrafts = buildAllSections(parsed, historyResults, searchSuggestions, searchEngine, params.spaces ?? [], params.autofill ?? true);
	} else {
		sectionDrafts = buildScopedSections(parsed.scope, parsed.query, historyResults, params.spaces ?? []);
	}

	const flatResults: CommandResult[] = [];
	const nextSections: CommandSection[] = [];

	for (const section of sectionDrafts) {
		if (section.items.length === 0) continue;
		const items = section.items.map((result) => {
			const index = flatResults.length;
			flatResults.push(result);
			return { index, result };
		});
		nextSections.push({
			id: section.id,
			title: section.title,
			subtitle: section.subtitle,
			items,
		});
	}

	const pinnedIndex = currentSelectedId
		? flatResults.findIndex((result) => result.id === currentSelectedId)
		: -1;
	const selectedIndex =
		pinnedIndex >= 0
			? pinnedIndex
			: flatResults.length === 0
				? 0
				: Math.min(currentSelectedIndex, flatResults.length - 1);

	return {
		results: flatResults,
		sections: nextSections,
		selectedIndex,
		activeScope: parsed.scope,
	};
}

