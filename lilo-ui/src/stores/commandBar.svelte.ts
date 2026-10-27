import { on } from "../lib/bridge";
import { omniboxActions, searchActions, settingsActions, tabActions, terminalActions } from "../lib/bridge/actions";
import { copyText } from "../lib/clipboard";
import type { BridgeArchivedTab, BridgeClosedTerminal, BridgeTerminalCompletion, BridgeTerminalSummary } from "../lib/bridge/protocol";
import { getEnabledExtensions, matchOmniboxKeyword } from "./extensions.svelte";
import {
	type CommandScope,
	parseInput,
	scopePrefix,
} from "../lib/inputParser";
import { getActiveTab, getOpenTabs, getTabs, isBlankTab, type TabState } from "./tabs.svelte";
import { onSidebarApplied, type SidebarAppliedEvent } from "./sidebar.svelte";
import { getPagedSpaces } from "./pager.svelte";
import { closeDesignSystemShell, closeSettingsShell } from "./panels.svelte";
import {
	type CommandResult,
	type CommandSection,
	type SearchableEntry,
	computeResults as _computeResults,
	getLocalHostCompletion,
	normalizeSearchSuggestions,
	HISTORY_SEARCH_DEBOUNCE_MS,
	noteActiveTab,
	toHistoryResults,
} from "./commandBarSearch.svelte";
import {
	executeResult as _executeResult,
	executeResultInNewTab as _executeResultInNewTab,
	executeRawQuery as _executeRawQuery,
	executeRawQueryInNewTab as _executeRawQueryInNewTab,
} from "./commandBarActions.svelte";

type CommandBarMode = "default" | "history";
/** An action on the selected row beyond Enter. */
export type ResultKey = "newTab" | "split" | "peek" | "copy" | "close" | "remove" | "move";

let _open = $state(false);
let _query = $state("");
let _results = $state.raw<CommandResult[]>([]);
let _sections = $state.raw<CommandSection[]>([]);
let _selectedIndex = $state(0);
// Set once the user picks a row (arrows, hover): late results then keep that row selected; until
// then the selection stays on the top row, so Enter does what the top row shows.
let _selectionMoved = false;
// Off after a deletion until the next insertion, so backspacing never completes a host back.
let _autofill = $state(true);
let _historyResults: CommandResult[] = [];
let _searchSuggestions: string[] = [];
let _mode = $state<CommandBarMode>("default");
let _activeScope = $state<CommandScope>("all");
let _closeBlankTabOnDismiss = false;
let _selectAllOnOpen = false;
let _openRequestId = $state(0);
let _suggestTimer: ReturnType<typeof setTimeout> | null = null;
let _pendingHistoryQuery = "";
let _pendingSuggestionQuery = "";
let _executed = false;
let _dismissBlankTabId = "";
let _pendingBlankTabClose = false;
// Blank tab we couldn't close on dismiss (it was the last tab, and closing it would close the
// window). We close it once another tab becomes active, leaving just that tab.
let _blankTabToCloseOnActivation = "";
let _searchEngine = "google";
// Extension omnibox session: non-empty sessionId while a registered keyword is active.
let _omniboxSessionId = "";
let _omniboxSeq = 0;
let _omniboxTitle = "";
let _omniboxResults: CommandResult[] = [];
let _terminalCompletions: BridgeTerminalCompletion[] = [];
let _terminals: BridgeTerminalSummary[] = [];
let _closedTerminals: BridgeClosedTerminal[] = [];
let _pendingTerminalQuery = "";
let _terminalListsRequested = false;
let _archivedTabs: BridgeArchivedTab[] = [];
let _archivedTabsRequested = false;
// The tab a Cmd+M picks a Space for, and the query to return to when the pick is cancelled.
let _moveTabId = $state("");
let _queryBeforeMove = "";

export const isCommandBarOpen = (): boolean => _open;
export const getQuery = (): string => _query;
export const getResults = (): CommandResult[] => _results;
export const getSections = (): CommandSection[] => _sections;
export const getSelectedIndex = (): number => _selectedIndex;
export const getSelectedResult = (): CommandResult | undefined =>
	_results[_selectedIndex];
export const getAutocompleteSuggestion = (): string => {
	const parsed = getParsedInput();
	if (parsed.type === "terminal") {
		// The ghost text completes the input as typed, prefix included.
		const command = parsed.query
			? _terminalCompletions.find((item) => item.command.startsWith(parsed.query) && item.command !== parsed.query)?.command
			: undefined;
		return command ? _query.trim() + command.slice(parsed.query.length) : "";
	}
	// The ghost text only names what Enter opens: the site root the selected top row goes to.
	const top = _results[0];
	if (!_autofill || parsed.scope !== "all" || parsed.type === "action" || _selectedIndex !== 0 || !top?.url) return "";
	if (top.kind !== "tab" && top.kind !== "bookmark" && top.kind !== "history" && top.kind !== "navigate") return "";
	return /^https?:\/\/[^/?#]+\/?$/i.test(top.url) ? getLocalHostCompletion(parsed.query, [top.url]) : "";
};
export const getCommandBarOpenRequestId = (): number => _openRequestId;
export const getActiveScope = (): CommandScope => _activeScope;
export const isMovingTab = (): boolean => _moveTabId !== "";
const openHistoryView = (): void => openCommandBar("", "history", false);
export const selectNext = (): void => shiftSelection(1);
export const selectPrev = (): void => shiftSelection(-1);
export const consumeSelectAllOnOpen = (): boolean => {
	const selectAll = _selectAllOnOpen;
	_selectAllOnOpen = false;
	return selectAll;
};

function clearSuggestTimer(): void {
	if (_suggestTimer) clearTimeout(_suggestTimer);
	_suggestTimer = null;
}

function currentDefaultScope(): CommandScope {
	return _mode === "history" ? "history" : "all";
}

function getParsedInput() {
	return parseInput(_query, currentDefaultScope());
}

function getTrackedBlankTab(): TabState | undefined {
	if (!_dismissBlankTabId) return undefined;
	return getOpenTabs().find((tab) => tab.id === _dismissBlankTabId);
}

// Never close the last open tab: closing it would close the whole window. Defer instead and
// close it once another tab is active (see handleSidebarApplied).
function closeBlankTabKeepingWindow(tabId: string): void {
	if (getOpenTabs().length <= 1) {
		_blankTabToCloseOnActivation = tabId;
		return;
	}
	tabActions.close(tabId);
}

function closeTrackedBlankTab(): void {
	const blankTab = getTrackedBlankTab();
	if (isBlankTab(blankTab)) {
		closeBlankTabKeepingWindow(blankTab.id);
	}
}

function finishExecution(closeBlankTab = false): void {
	_executed = !closeBlankTab;
	closeCommandBar();
}

/**
 * Runs after the sidebar store applied a structural change, so the store getters are current and listener
 * registration order cannot matter.
 */
function handleSidebarApplied(event: SidebarAppliedEvent): void {
	const activeTab = event.activeTab;
	noteActiveTab(event.activeTabId);

	// A blank tab we deferred closing on dismiss: close it once another real tab is active
	// (safe once it is no longer the last tab). Drop the deferral if it's gone or navigated.
	if (_blankTabToCloseOnActivation) {
		const blankTab = getOpenTabs().find((tab) => tab.id === _blankTabToCloseOnActivation);
		if (isBlankTab(blankTab) && activeTab && activeTab.id !== blankTab.id && getOpenTabs().length > 1) {
			_blankTabToCloseOnActivation = "";
			tabActions.close(blankTab.id);
		} else if (!isBlankTab(blankTab)) {
			_blankTabToCloseOnActivation = "";
		}
	}

	if (_open && _closeBlankTabOnDismiss && !_dismissBlankTabId && isBlankTab(activeTab)) {
		_dismissBlankTabId = activeTab.id;
	}

	if (_pendingBlankTabClose) {
		if (isBlankTab(activeTab)) {
			closeBlankTabKeepingWindow(activeTab.id);
		}
		_pendingBlankTabClose = false;
		return;
	}

	if (
		_open &&
		_closeBlankTabOnDismiss &&
		_dismissBlankTabId &&
		activeTab &&
		activeTab.id !== _dismissBlankTabId
	) {
		closeCommandBar();
		return;
	}

	if (_open && _closeBlankTabOnDismiss && _dismissBlankTabId) {
		// The tracked blank tab is gone (closed/pruned) or navigated to a real URL.
		const trackedTab = getTabs(event.spaceId).find(
			(tab) => tab.id === _dismissBlankTabId,
		);
		if (
			!trackedTab ||
			trackedTab.isClosed ||
			event.closedTabIds.includes(_dismissBlankTabId) ||
			(typeof trackedTab.url === "string" && trackedTab.url.length > 0)
		) {
			closeCommandBar();
		}
	}
}

function shiftSelection(delta: number): void {
	if (_results.length === 0) return;
	_selectedIndex = (_selectedIndex + delta + _results.length) % _results.length;
	_selectionMoved = true;
}

export function setSelectedIndex(index: number): void {
	if (index < 0 || index >= _results.length) return;
	_selectedIndex = index;
	_selectionMoved = true;
}

export function autocompleteSelected(): void {
	const selected = _results[_selectedIndex];
	if (selected?.kind === "terminal") {
		setQuery(`${scopePrefix("terminal")}${selected.payload.command as string}`);
	} else if (selected?.url && selected.kind !== "search") {
		setQuery(selected.url);
	}
}

export function setCommandBarScope(scope: CommandScope): void {
	// Picking a scope leaves the one-shot "history-direct" mode, or `currentDefaultScope()` stays pinned to "history"
	// and the prefix-less "all" scope would re-derive it.
	_mode = "default";
	const parsed = getParsedInput();
	const nextQuery =
		scope === "all"
			? parsed.query
			: parsed.query
				? `${scopePrefix(scope)} ${parsed.query}`
				: scopePrefix(scope);
	setQuery(nextQuery);
}

function computeResults(options: { pinSelection?: boolean } = {}): void {
	const parsed = getParsedInput();
	const pinnedId = options.pinSelection && _selectionMoved ? getSelectedResult()?.id : undefined;
	const output = _computeResults(
		{
			parsed,
			historyResults: _historyResults,
			searchSuggestions: _searchSuggestions,
			searchEngine: _searchEngine,
			terminalCompletions: _terminalCompletions,
			terminals: _terminals,
			closedTerminals: _closedTerminals,
			archivedTabs: _archivedTabs,
			spaces: getPagedSpaces(),
			moveTabId: _moveTabId,
			autofill: _autofill,
			omnibox: {
				active: !!_omniboxSessionId,
				title: _omniboxTitle,
				results: _omniboxResults,
			},
		},
		_selectedIndex,
		pinnedId,
	);
	_results = output.results;
	_sections = output.sections;
	_selectedIndex = output.selectedIndex;
	_activeScope = output.activeScope;
}

function clearOmniboxSession(cancel: boolean): void {
	if (_omniboxSessionId && cancel) omniboxActions.inputCancelled(_omniboxSessionId);
	_omniboxSessionId = "";
	_omniboxTitle = "";
	_omniboxResults = [];
}

function makeOmniboxResult(
	description: string,
	content: string,
	isDefault: boolean,
	deletable = false,
): CommandResult {
	return {
		id: `omnibox-${isDefault ? "default" : content}`,
		kind: "omnibox",
		title: description || content,
		payload: { content, description, deletable },
	};
}

/** Drops a suggestion its extension marked deletable and tells the extension (onDeleteSuggestion). */
function deleteOmniboxSuggestion(result: CommandResult): void {
	if (result.kind !== "omnibox" || result.payload.deletable !== true) return;
	_omniboxResults = _omniboxResults.filter((r) => r !== result);
	omniboxActions.deleteSuggestion(_query, result.payload.description as string);
	computeResults({ pinSelection: true });
}

function submitOmnibox(disposition: string): void {
	const selected = _results[_selectedIndex];
	const match = matchOmniboxKeyword(_query);
	const text =
		selected?.kind === "omnibox"
			? (selected.payload.content as string)
			: (match?.text ?? "");
	const query = _query;
	const sessionId = _omniboxSessionId;
	clearOmniboxSession(false); // entered, not cancelled, so closing won't fire onInputCancelled
	omniboxActions.inputEntered(sessionId, query, text, disposition);
	closeCommandBarAfterNavigation();
}

function scheduleSearchSuggest(query: string): void {
	clearSuggestTimer();
	if (_moveTabId) {
		computeResults();
		return;
	}

	// Extension omnibox keyword session takes over the bar: stream input to the extension and show
	// only its suggestions (skip the normal history/search pipeline).
	const omniboxMatch = _mode === "default" ? matchOmniboxKeyword(query) : null;
	if (omniboxMatch) {
		if (!_omniboxSessionId) {
			_omniboxSessionId = `omni-${++_omniboxSeq}`;
			omniboxActions.inputStarted(_omniboxSessionId, query);
		}
		_omniboxTitle =
			getEnabledExtensions().find((e) => e.id === omniboxMatch.extensionId)?.name ??
			omniboxMatch.keyword;
		const sessionId = _omniboxSessionId;
		_suggestTimer = setTimeout(
			() => omniboxActions.inputChanged(sessionId, query),
			90,
		);
		computeResults();
		return;
	}
	clearOmniboxSession(true);

	const parsed = parseInput(query, currentDefaultScope());
	if (parsed.type === "terminal") {
		const command = parsed.query;
		// Completions of a shorter prefix stay valid while typing, so they are kept until the answer arrives.
		_terminalCompletions = _terminalCompletions.filter((item) => item.command.startsWith(command));
		_pendingTerminalQuery = command;
		computeResults();
		// The host ships the terminal lists only for an empty query: ask once per opening, right away,
		// so typing past ">" within the debounce still gets them.
		if (!_terminalListsRequested) {
			_terminalListsRequested = true;
			terminalActions.complete("");
			if (!command) return;
		}
		_suggestTimer = setTimeout(() => terminalActions.complete(command), 40);
		return;
	}

	if (parsed.scope === "archive") {
		computeResults();
		// Asked once per opening; typing filters the list here.
		if (!_archivedTabsRequested) {
			_archivedTabsRequested = true;
			tabActions.loadArchived();
		}
		return;
	}

	const searchesHistory = parsed.scope === "all" || parsed.scope === "history";
	if (!parsed.query && searchesHistory) {
		_pendingHistoryQuery = "";
		_pendingSuggestionQuery = "";
		_historyResults = [];
		_searchSuggestions = [];
		searchActions.loadRecentHistory();
	} else if (parsed.query && searchesHistory) {
		// Stale results stay visible until the new search returns, avoiding an empty flash.
		_pendingHistoryQuery = parsed.query;
		_pendingSuggestionQuery = parsed.query;
	}

	computeResults();

	if (parsed.query && searchesHistory) {
		const pendingQuery = parsed.query;
		_suggestTimer = setTimeout(() => {
			searchActions.searchHistory(pendingQuery);
			if (parsed.scope === "all" && parsed.type === "search") {
				searchActions.searchSuggestions(pendingQuery, _searchEngine);
			}
		}, HISTORY_SEARCH_DEBOUNCE_MS);
	}
}

function setHistoryResults(query: string, items: SearchableEntry[]): void {
	if (query !== _pendingHistoryQuery) return;
	_historyResults = toHistoryResults(items, query);
	computeResults({ pinSelection: true });
}

function setSearchSuggestions(query: string, items: string[]): void {
	const pending = _pendingSuggestionQuery;
	// Replies arrive in query order, so on a slow link the one for a prefix of what is typed, kept to
	// what still matches, beats none until the exact one lands.
	if (query !== pending) {
		if (!query || !pending.startsWith(query)) return;
		const typed = pending.toLowerCase();
		items = items.filter((item) => item.toLowerCase().startsWith(typed));
	}
	_searchSuggestions = normalizeSearchSuggestions(pending, items);
	computeResults({ pinSelection: true });
}

export function openCommandBar(
	prefill?: string,
	mode: CommandBarMode = "default",
	closeBlankTabOnDismiss = false,
	selectAllOnOpen = false,
): void {
	_open = true;
	_mode = mode;
	_query = prefill ?? "";
	_selectedIndex = 0;
	_selectionMoved = false;
	_closeBlankTabOnDismiss = closeBlankTabOnDismiss;
	_pendingBlankTabClose = false;
	_blankTabToCloseOnActivation = "";
	_selectAllOnOpen = selectAllOnOpen;
	const activeTab = getActiveTab();
	_dismissBlankTabId = closeBlankTabOnDismiss && isBlankTab(activeTab) ? activeTab.id : "";
	_openRequestId += 1;
	scheduleSearchSuggest(_query);
}

export function closeCommandBar(): void {
	clearOmniboxSession(true);
	const closeBlankTab = !_executed && _closeBlankTabOnDismiss;
	_open = false;
	_query = "";
	_results = [];
	_sections = [];
	_selectedIndex = 0;
	_selectionMoved = false;
	_historyResults = [];
	_searchSuggestions = [];
	_mode = "default";
	_activeScope = "all";
	_executed = false;
	_selectAllOnOpen = false;
	_pendingHistoryQuery = "";
	_pendingSuggestionQuery = "";
	_terminalCompletions = [];
	_terminals = [];
	_closedTerminals = [];
	_pendingTerminalQuery = "";
	_terminalListsRequested = false;
	_archivedTabs = [];
	_archivedTabsRequested = false;
	_moveTabId = "";
	_queryBeforeMove = "";
	clearSuggestTimer();
	if (closeBlankTab) {
		if (_dismissBlankTabId) {
			closeTrackedBlankTab();
			_pendingBlankTabClose = false;
		} else {
			// New tab not yet reflected in store; close it once the state arrives.
			_pendingBlankTabClose = true;
		}
	} else {
		_pendingBlankTabClose = false;
	}
	_closeBlankTabOnDismiss = false;
	_dismissBlankTabId = "";
}

// A navigation has to land on the page: the settings and design system shells cover it.
function closeCommandBarAfterNavigation(): void {
	_executed = true;
	closeCommandBar();
	closeSettingsShell();
	closeDesignSystemShell();
}

export function setQuery(query: string, autofill = true): void {
	_query = query;
	_autofill = autofill;
	_selectedIndex = 0;
	_selectionMoved = false;
	scheduleSearchSuggest(query);
}

export function dismissAutofill(): void {
	_autofill = false;
	computeResults();
}

export function executeSelected(): void {
	if (_omniboxSessionId) {
		submitOmnibox("currentTab");
		return;
	}
	const result = _results[_selectedIndex];
	if (result) executeResult(result);
}

export function executeSelectedInNewTab(): void {
	if (_omniboxSessionId) {
		submitOmnibox("newForegroundTab");
		return;
	}
	const result = _results[_selectedIndex];
	if (result) executeResultInNewTab(result);
}

export function executeResult(result: CommandResult): void {
	_executeResult(result, finishExecution);
}

function executeResultInNewTab(result: CommandResult): void {
	_executeResultInNewTab(result, finishExecution);
}

const WEB_URL = /^https?:\/\//i;

/** The actions the selected row answers to beyond Enter, in footer order. */
export function getSelectedResultKeys(): ResultKey[] {
	const result = _results[_selectedIndex];
	if (!result) return getParsedInput().query && !_moveTabId ? ["newTab"] : [];
	const keys: ResultKey[] = [];
	const isTab = result.kind === "tab" || result.kind === "bookmark";
	const isPage = isTab || result.kind === "history" || result.kind === "navigate" || result.kind === "search";
	const web = isPage && WEB_URL.test(result.url ?? "");
	if (isPage || result.kind === "terminal" || result.kind === "omnibox") keys.push("newTab");
	if (isTab || web) keys.push("split");
	if (web) keys.push("peek");
	if (result.url) keys.push("copy");
	if (result.kind === "tab") keys.push("close", "move");
	if ((result.kind === "history" && result.url) || (result.kind === "omnibox" && result.payload.deletable === true)) {
		keys.push("remove");
	}
	return keys;
}

// Drops the selected row where it stands: the next row takes the selection.
function dropSelectedRow(): void {
	const dropped = _results[_selectedIndex];
	_results = _results.filter((result) => result !== dropped);
	let index = 0;
	_sections = _sections
		.map((section) => ({
			...section,
			items: section.items
				.filter((entry) => entry.result !== dropped)
				.map((entry) => ({ index: index++, result: entry.result })),
		}))
		.filter((section) => section.items.length > 0);
	_selectedIndex = Math.min(_selectedIndex, Math.max(0, _results.length - 1));
}

/**
 * Runs `key` on the selected row; false when the row has no such action, so the key does its usual
 * job. "newTab" stays with Enter's own handling.
 */
export function runSelectedResultKey(key: Exclude<ResultKey, "newTab">): boolean {
	const result = _results[_selectedIndex];
	if (!result || !getSelectedResultKeys().includes(key)) return false;
	// getSelectedResultKeys offers a key that opens or copies the URL only for a row that has one.
	const url = result.url ?? "";
	if (key === "split") {
		if (result.kind === "tab" || result.kind === "bookmark") tabActions.splitTab(result.payload.tabId as string, "right");
		else tabActions.splitURL(url, "right");
		finishExecution(false);
	} else if (key === "peek") {
		// The peek opens over the active tab, blank or not: it stays.
		tabActions.peekURL(url);
		finishExecution(false);
	} else if (key === "copy") {
		void copyText(url);
		finishExecution(true);
	} else if (key === "close") {
		tabActions.close(result.payload.tabId as string);
		dropSelectedRow();
	} else if (key === "remove") {
		if (result.kind === "history") searchActions.deleteHistory(url, _query);
		else deleteOmniboxSuggestion(result);
	} else if (key === "move") {
		_queryBeforeMove = _query;
		_moveTabId = result.payload.tabId as string;
		setQuery("");
	}
	return true;
}

/** Leaves the Space picker of a tab move, back to the query it started from. */
export function cancelMoveTab(): void {
	_moveTabId = "";
	setQuery(_queryBeforeMove);
}

export function executeRawQuery(): void {
	if (_omniboxSessionId) {
		submitOmnibox("currentTab");
		return;
	}
	_executeRawQuery(getParsedInput(), _searchEngine, finishExecution);
}

export function executeRawQueryInNewTab(): void {
	if (_omniboxSessionId) {
		submitOmnibox("newForegroundTab");
		return;
	}
	_executeRawQueryInNewTab(getParsedInput(), _searchEngine, finishExecution);
}

export function initCommandBarStore(): void {
	document.addEventListener("visibilitychange", () => {
		if (document.hidden) clearSuggestTimer();
	});
	settingsActions.load();
	on("settingsLoaded", (data) => {
		_searchEngine = data.settings?.searchEngine ?? "google";
		if (_open) computeResults();
	});
	on("historyResults", (data) =>
		setHistoryResults(data.query ?? "", data.results ?? []),
	);
	on("terminalCompletionResults", (data) => {
		// The lists ride only the empty-query reply, which stays valid after newer keystrokes.
		if (data.terminals) _terminals = data.terminals;
		if (data.closedTerminals) _closedTerminals = data.closedTerminals;
		if (data.query === _pendingTerminalQuery) _terminalCompletions = data.items;
		else if (!data.terminals) return;
		computeResults({ pinSelection: true });
	});
	// Native builds this list like the completion reply's, so it refreshes an open bar's terminals for free.
	on("terminalActivity", (data) => {
		if (!_open || !_terminalListsRequested) return;
		_terminals = data.terminals;
		computeResults({ pinSelection: true });
	});
	on("archivedTabs", (data) => {
		if (!_open) return;
		_archivedTabs = data.tabs;
		computeResults({ pinSelection: true });
	});
	on("searchSuggestions", (data) =>
		setSearchSuggestions(data.query ?? "", data.suggestions ?? []),
	);
	on("omniboxSuggestions", (data) => {
		if (!_omniboxSessionId || data.sessionId !== _omniboxSessionId) return;
		const results: CommandResult[] = [];
		if (data.defaultSuggestion) {
			const match = matchOmniboxKeyword(_query);
			results.push(
				makeOmniboxResult(data.defaultSuggestion, match?.text ?? _query, true),
			);
		}
		for (const suggestion of data.suggestions ?? []) {
			results.push(
				makeOmniboxResult(suggestion.description, suggestion.content, false, suggestion.deletable === true),
			);
		}
		_omniboxResults = results;
		computeResults({ pinSelection: true });
	});
	onSidebarApplied(handleSidebarApplied);
	on("openCommandBar", (data) =>
		openCommandBar(
			data?.newTab ? "" : data?.prefill,
			"default",
			data?.newTab ?? false,
			data?.selectAll ?? false,
		),
	);
	on("openHistory", openHistoryView);
	on("closeCommandBarAfterNavigation", closeCommandBarAfterNavigation);
	on("toggleCommandBar", (data) => {
		if (_open) {
			// Cmd+L on an open bar keeps the typed text and reselects it.
			_selectAllOnOpen = true;
			_openRequestId += 1;
		} else {
			openCommandBar(data?.prefill ?? "", "default", false, data?.selectAll ?? false);
		}
	});
}
