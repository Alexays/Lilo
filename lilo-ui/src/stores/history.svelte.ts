import { on } from "../lib/bridge";
import { historyActions, tabActions } from "../lib/bridge/actions";
import type {
	BridgeEventPayloadMap,
	BridgeHistoryDayRow,
	BridgeHistoryFilter,
	BridgeHistoryPeriod,
} from "../lib/bridge/protocol";
import { keysBetween, rowKey } from "../components/history/historyPageModel";
import { closeHistoryShell, isHistoryShellOpen, openHistoryShell } from "./panels.svelte";

type Sidebar = BridgeEventPayloadMap["historySidebar"];

const EMPTY_FILTER: BridgeHistoryFilter = { query: "", period: "all" };
/** Typing pauses this long before a search reaches the database. */
const QUERY_DELAY_MS = 150;

let _filter = $state.raw<BridgeHistoryFilter>(EMPTY_FILTER);
let _rows = $state.raw<BridgeHistoryDayRow[]>([]);
let _nextBefore = $state<number | undefined>(undefined);
let _loading = $state(false);
let _loaded = $state(false);
let _sidebar = $state.raw<Sidebar | null>(null);
let _favicons = $state.raw<Record<string, string>>({});
let _selection = $state.raw<ReadonlySet<string>>(new Set());
let _anchor: string | null = null;
let _requestId = 0;
let _appending = false;
let _batches = 0;
let _queryTimer: ReturnType<typeof setTimeout> | null = null;
let _listening = false;

export const getHistoryFilter = (): BridgeHistoryFilter => _filter;
export const getHistoryRows = (): BridgeHistoryDayRow[] => _rows;
export const hasMoreHistory = (): boolean => _nextBefore !== undefined;
export const isHistoryLoading = (): boolean => _loading;
export const isHistoryLoaded = (): boolean => _loaded;
export const getHistorySidebar = (): Sidebar | null => _sidebar;
export const getHistoryFavicon = (host: string): string | undefined => _favicons[host];
export const getHistorySelection = (): ReadonlySet<string> => _selection;

function request(before?: number): void {
	_requestId += 1;
	_appending = before !== undefined;
	_loading = true;
	historyActions.loadPage({ ..._filter, requestId: _requestId, before });
}

function reload(): void {
	if (_queryTimer) clearTimeout(_queryTimer);
	_queryTimer = null;
	request();
}

function setFilter(filter: BridgeHistoryFilter): void {
	_filter = filter;
	setSelection(new Set());
	reload();
}

function setSelection(selection: ReadonlySet<string>): void {
	_selection = selection;
	if (selection.size === 0) _anchor = null;
}

export function openHistory(filter: Partial<BridgeHistoryFilter> = {}): void {
	initHistoryStore();
	_filter = { ...EMPTY_FILTER, ...filter };
	setSelection(new Set());
	openHistoryShell();
	reload();
	historyActions.loadSidebar();
}

export function closeHistory(): void {
	closeHistoryShell();
	setSelection(new Set());
}

export function loadMoreHistory(): void {
	if (!_loading && _nextBefore !== undefined) request(_nextBefore);
}

export function setHistoryQuery(query: string): void {
	_filter = { ..._filter, query };
	setSelection(new Set());
	if (_queryTimer) clearTimeout(_queryTimer);
	_queryTimer = setTimeout(reload, QUERY_DELAY_MS);
}

/** A period, a site or a terminal: one at a time, the search stays. */
export function showHistoryPeriod(period: BridgeHistoryPeriod): void {
	setFilter({ query: _filter.query, period });
}

export function showHistorySite(host: string): void {
	setFilter({ query: _filter.query, period: "all", host });
}

export function showHistoryTerminal(openedFrom: string): void {
	setFilter({ query: _filter.query, period: "all", openedFrom });
}

/** Escape unwinds one level: the search, then a site or terminal, then the page. */
export function unwindHistory(): void {
	if (_filter.query) setFilter({ ..._filter, query: "" });
	else if (_filter.host !== undefined || _filter.openedFrom !== undefined || _filter.period !== "all") setFilter(EMPTY_FILTER);
	else closeHistory();
}

export function toggleHistoryRow(key: string): void {
	const next = new Set(_selection);
	if (next.has(key)) next.delete(key);
	else next.add(key);
	_anchor = key;
	setSelection(next);
}

export function extendHistorySelection(key: string): void {
	const next = new Set(_selection);
	for (const k of keysBetween(_rows, _anchor ?? key, key)) next.add(k);
	_anchor ??= key;
	setSelection(next);
}

export function selectAllHistory(): void {
	setSelection(new Set(_rows.map(rowKey)));
}

export function clearHistorySelection(): void {
	setSelection(new Set());
}

/** The current tab shows it (a terminal hands it a new tab), or a background tab when `background`. */
export function openHistoryRow(row: BridgeHistoryDayRow, background: boolean): void {
	if (background) {
		tabActions.create(row.url, false, true);
		return;
	}
	tabActions.navigate(row.url);
	closeHistory();
}

export function openHistoryRowInNewTab(row: BridgeHistoryDayRow): void {
	tabActions.create(row.url);
	closeHistory();
}

/** The selected rows in list order: the first in front, the others behind it. */
export function openSelectedHistory(): void {
	const urls = _rows.filter((row) => _selection.has(rowKey(row))).map((row) => row.url);
	urls.forEach((url, index) => tabActions.create(url, false, index > 0));
	if (urls.length) closeHistory();
}

/** Deletes `keys`' visits; the rows go at once, the store reloads the rest on `historyChanged`. */
export function deleteHistoryRows(keys: ReadonlySet<string>): void {
	const rows = _rows.filter((row) => keys.has(rowKey(row)));
	if (!rows.length) return;
	historyActions.deleteRows({
		rows: rows.map((row) => ({ pageId: row.pageId, dayStart: row.dayStart })),
		openedFrom: _filter.openedFrom,
	});
	_rows = _rows.filter((row) => !keys.has(rowKey(row)));
	setSelection(new Set([..._selection].filter((key) => !keys.has(key))));
}

export function deleteHistorySite(host: string): void {
	historyActions.deleteSite(host);
	_rows = _rows.filter((row) => row.host !== host);
	setSelection(new Set([..._selection].filter((key) => _rows.some((row) => rowKey(row) === key))));
}

/** Listens once, on the first open: the page asks before any of its replies can arrive. */
function initHistoryStore(): void {
	if (_listening) return;
	_listening = true;

	on("historyPage", (data) => {
		if (data.requestId !== _requestId) return;
		_rows = _appending ? [..._rows, ...data.rows] : data.rows;
		_batches = _appending ? _batches + 1 : 1;
		_nextBefore = data.nextBefore;
		if (Object.keys(data.favicons).length) _favicons = { ..._favicons, ...data.favicons };
		_loading = false;
		_loaded = true;
		if (!_appending && _selection.size) {
			const keys = new Set(_rows.map(rowKey));
			setSelection(new Set([..._selection].filter((key) => keys.has(key))));
		}
	});

	on("historySidebar", (data) => {
		_sidebar = data;
	});

	// New visits or a deletion: the counts follow, and the list too unless the user scrolled into older batches.
	on("historyChanged", () => {
		if (!isHistoryShellOpen()) return;
		historyActions.loadSidebar();
		if (_batches <= 1) reload();
	});
}
