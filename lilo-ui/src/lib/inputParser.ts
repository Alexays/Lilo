import {
	BUILTIN_SEARCH_ENGINES,
	buildSearchURLFromTemplate,
	findEngineById,
	findEngineByKeyword,
	type SearchEngine,
} from "./searchEngineModel";

export type CommandActionId =
	| "createTab"
	| "createSpace"
	| "openSettings"
	| "openFeatureFlags"
	| "openProcessManager"
	| "replayOnboarding"
	| "createPrivateSpace"
	| "closeActiveTab"
	| "toggleSidebar"
	| "moveTabsLeft"
	| "moveTabsRight"
	| "moveTabsTop"
	| "moveTabsBottom"
	| "reloadPage"
	| "goBack"
	| "goForward"
	| "stopLoading"
	| "zoomIn"
	| "zoomOut"
	| "resetZoom"
	| "captureFullPage"
	| "findInPage"
	| "toggleReader"
	| "copyPageURL"
	| "togglePinActiveTab"
	| "duplicateActiveTab"
	| "showDownloads"
	| "showHistory"
	| "captureArea"
	| "openPasswordsApp"
	| "reopenClosedTab"
	| "clearUnpinnedTabs"
	| "muteActiveTab"
	| "bookmarkActivePage"
	| "translatePage"
	| "viewPageSource"
	| "savePageAs"
	| "newSplitView"
	| "closeSplitView"
	| "newTerminal"
	| "nextWaitingTerminal"
	| "showChanges";

export type CommandScope =
	| "all"
	| "action"
	| "terminal"
	| "tab"
	| "bookmark"
	| "history"
	| "archive";

export interface CommandActionDefinition {
	id: CommandActionId;
	// `commandBar.actions.<id>` / `<id>Desc` catalog keys; the consumer resolves them with t().
	nameKey: string;
	descriptionKey: string;
	// A line icon name from LINE_ICONS (components/commandbar/commandBarIcons.ts).
	icon: string;
	keywords: readonly string[];
	// The native action whose keys the row shows (an id of KeyboardShortcuts.swift).
	shortcutId?: string;
}

interface ParsedInputBase {
	type: "url" | "search" | "action" | "terminal";
	scope: CommandScope;
	query: string;
}

export type ParsedInput =
	| (ParsedInputBase & { type: "url"; url: string })
	| (ParsedInputBase & { type: "search" })
	// `action` is undefined for a free-form `:`-scope query that matches no known command.
	| (ParsedInputBase & { type: "action"; action?: CommandActionId })
	// A shell command for a new terminal tab; `query` is the command as typed.
	| (ParsedInputBase & { type: "terminal" });

const COMMAND_SCOPE_PREFIXES: Record<
	Exclude<CommandScope, "all">,
	string
> = {
	action: ":",
	terminal: ">",
	tab: "@",
	bookmark: "#",
	history: "/",
	archive: "<",
};

export const COMMAND_ACTIONS = [
	{
		id: "createTab",
		nameKey: "commandBar.actions.createTab",
		descriptionKey: "commandBar.actions.createTabDesc",
		icon: "plus",
		keywords: ["new tab", "newtab", "open tab", "create tab"],
		shortcutId: "tab.new",
	},
	{
		id: "closeActiveTab",
		nameKey: "commandBar.actions.closeActiveTab",
		descriptionKey: "commandBar.actions.closeActiveTabDesc",
		icon: "closeTab",
		keywords: ["close tab", "close current tab", "close active tab"],
		shortcutId: "tab.close",
	},
	{
		id: "openSettings",
		nameKey: "commandBar.actions.openSettings",
		descriptionKey: "commandBar.actions.openSettingsDesc",
		icon: "gear",
		keywords: ["settings", "preferences", "open settings", "open preferences"],
		shortcutId: "app.settings",
	},
	{
		id: "openFeatureFlags",
		nameKey: "commandBar.actions.openFeatureFlags",
		descriptionKey: "commandBar.actions.openFeatureFlagsDesc",
		icon: "flag",
		keywords: [
			"config",
			"about:config",
			"feature flags",
			"flags",
			"webkit features",
			"experiments",
		],
	},
	{
		id: "openProcessManager",
		nameKey: "commandBar.actions.openProcessManager",
		descriptionKey: "commandBar.actions.openProcessManagerDesc",
		icon: "pulse",
		keywords: [
			"process manager",
			"processes",
			"webkit processes",
			"task manager",
			"process diagnostics",
		],
		shortcutId: "app.processManager",
	},
	{
		id: "replayOnboarding",
		nameKey: "commandBar.actions.replayOnboarding",
		descriptionKey: "commandBar.actions.replayOnboardingDesc",
		icon: "sparkle",
		keywords: ["onboarding", "welcome", "tour", "import", "accueil", "bienvenue"],
	},
	{
		id: "createSpace",
		nameKey: "commandBar.actions.createSpace",
		descriptionKey: "commandBar.actions.createSpaceDesc",
		icon: "spaceAdd",
		keywords: ["new space", "create space"],
		shortcutId: "space.new",
	},
	{
		id: "createPrivateSpace",
		nameKey: "commandBar.actions.createPrivateSpace",
		descriptionKey: "commandBar.actions.createPrivateSpaceDesc",
		icon: "eyeOff",
		keywords: [
			"private",
			"private space",
			"new private space",
			"incognito space",
		],
		shortcutId: "space.newPrivate",
	},
	{
		id: "toggleSidebar",
		nameKey: "commandBar.actions.toggleSidebar",
		descriptionKey: "commandBar.actions.toggleSidebarDesc",
		icon: "sidebar",
		keywords: ["toggle sidebar", "sidebar", "show sidebar", "hide sidebar"],
		shortcutId: "sidebar.toggle",
	},
	{
		id: "moveTabsLeft",
		nameKey: "commandBar.actions.moveTabsLeft",
		descriptionKey: "commandBar.actions.moveTabsLeftDesc",
		icon: "sidebar",
		keywords: ["tabs left", "sidebar left", "tab position", "vertical tabs"],
		shortcutId: "tabs.positionLeft",
	},
	{
		id: "moveTabsRight",
		nameKey: "commandBar.actions.moveTabsRight",
		descriptionKey: "commandBar.actions.moveTabsRightDesc",
		icon: "sidebar",
		keywords: ["tabs right", "sidebar right", "tab position", "vertical tabs"],
		shortcutId: "tabs.positionRight",
	},
	{
		id: "moveTabsTop",
		nameKey: "commandBar.actions.moveTabsTop",
		descriptionKey: "commandBar.actions.moveTabsTopDesc",
		icon: "sidebar",
		keywords: ["tabs top", "tab bar", "tab position", "horizontal tabs"],
		shortcutId: "tabs.positionTop",
	},
	{
		id: "moveTabsBottom",
		nameKey: "commandBar.actions.moveTabsBottom",
		descriptionKey: "commandBar.actions.moveTabsBottomDesc",
		icon: "sidebar",
		keywords: ["tabs bottom", "tab bar", "tab position", "horizontal tabs", "dock"],
		shortcutId: "tabs.positionBottom",
	},
	{
		id: "reloadPage",
		nameKey: "commandBar.actions.reloadPage",
		descriptionKey: "commandBar.actions.reloadPageDesc",
		icon: "reload",
		keywords: ["reload", "refresh", "reload page"],
		shortcutId: "page.reload",
	},
	{
		id: "goBack",
		nameKey: "commandBar.actions.goBack",
		descriptionKey: "commandBar.actions.goBackDesc",
		icon: "back",
		keywords: ["back", "go back", "previous page", "history back"],
		shortcutId: "history.back",
	},
	{
		id: "goForward",
		nameKey: "commandBar.actions.goForward",
		descriptionKey: "commandBar.actions.goForwardDesc",
		icon: "forward",
		keywords: ["forward", "go forward", "next page", "history forward"],
		shortcutId: "history.forward",
	},
	{
		id: "stopLoading",
		nameKey: "commandBar.actions.stopLoading",
		descriptionKey: "commandBar.actions.stopLoadingDesc",
		icon: "stop",
		keywords: ["stop", "stop loading", "cancel loading"],
		shortcutId: "page.stop",
	},
	{
		id: "zoomIn",
		nameKey: "commandBar.actions.zoomIn",
		descriptionKey: "commandBar.actions.zoomInDesc",
		icon: "zoomIn",
		keywords: ["zoom in", "zoom", "bigger", "larger text", "magnify"],
		shortcutId: "zoom.in",
	},
	{
		id: "zoomOut",
		nameKey: "commandBar.actions.zoomOut",
		descriptionKey: "commandBar.actions.zoomOutDesc",
		icon: "zoomOut",
		keywords: ["zoom out", "smaller", "smaller text"],
		shortcutId: "zoom.out",
	},
	{
		id: "resetZoom",
		nameKey: "commandBar.actions.resetZoom",
		descriptionKey: "commandBar.actions.resetZoomDesc",
		icon: "zoomReset",
		keywords: ["actual size", "reset zoom", "default zoom", "100%"],
		shortcutId: "zoom.reset",
	},
	{
		id: "captureFullPage",
		nameKey: "commandBar.actions.captureFullPage",
		descriptionKey: "commandBar.actions.captureFullPageDesc",
		icon: "camera",
		keywords: ["screenshot", "capture", "full page", "screen capture", "snapshot"],
		shortcutId: "capture.fullPage",
	},
	{
		id: "findInPage",
		nameKey: "commandBar.actions.findInPage",
		descriptionKey: "commandBar.actions.findInPageDesc",
		icon: "find",
		keywords: ["find", "find on page", "search page", "find in page", "chercher"],
		shortcutId: "find.show",
	},
	{
		id: "toggleReader",
		nameKey: "commandBar.actions.toggleReader",
		descriptionKey: "commandBar.actions.toggleReaderDesc",
		icon: "reader",
		keywords: ["reader", "reader view", "reader mode", "read", "lecteur"],
		shortcutId: "page.reader",
	},
	{
		id: "copyPageURL",
		nameKey: "commandBar.actions.copyPageURL",
		descriptionKey: "commandBar.actions.copyPageURLDesc",
		icon: "link",
		keywords: ["copy url", "copy link", "copy address", "share link", "copier le lien"],
		shortcutId: "page.copyURL",
	},
	{
		id: "togglePinActiveTab",
		nameKey: "commandBar.actions.togglePinActiveTab",
		descriptionKey: "commandBar.actions.togglePinActiveTabDesc",
		icon: "pin",
		keywords: ["pin", "unpin", "pin tab", "unpin tab", "épingler"],
		shortcutId: "tab.pin",
	},
	{
		id: "duplicateActiveTab",
		nameKey: "commandBar.actions.duplicateActiveTab",
		descriptionKey: "commandBar.actions.duplicateActiveTabDesc",
		icon: "duplicate",
		keywords: ["duplicate", "duplicate tab", "copy tab", "dupliquer"],
		shortcutId: "tab.duplicate",
	},
	{
		id: "showDownloads",
		nameKey: "commandBar.actions.showDownloads",
		descriptionKey: "commandBar.actions.showDownloadsDesc",
		icon: "download",
		keywords: ["downloads", "download list", "files", "téléchargements"],
		shortcutId: "downloads.show",
	},
	{
		id: "showHistory",
		nameKey: "commandBar.actions.showHistory",
		descriptionKey: "commandBar.actions.showHistoryDesc",
		icon: "history",
		keywords: ["history", "all history", "visited pages", "historique"],
		shortcutId: "history.show",
	},
	{
		id: "captureArea",
		nameKey: "commandBar.actions.captureArea",
		descriptionKey: "commandBar.actions.captureAreaDesc",
		icon: "crop",
		keywords: ["screenshot", "capture area", "capture selection", "screen capture", "capture"],
		shortcutId: "capture.area",
	},
	{
		id: "openPasswordsApp",
		nameKey: "commandBar.actions.openPasswordsApp",
		descriptionKey: "commandBar.actions.openPasswordsAppDesc",
		icon: "key",
		keywords: ["passwords", "keychain", "icloud", "mots de passe"],
	},
	{
		id: "reopenClosedTab",
		nameKey: "commandBar.actions.reopenClosedTab",
		descriptionKey: "commandBar.actions.reopenClosedTabDesc",
		icon: "undo",
		keywords: ["reopen", "reopen tab", "restore tab", "undo close tab"],
		shortcutId: "tab.reopenClosed",
	},
	{
		id: "clearUnpinnedTabs",
		nameKey: "commandBar.actions.clearUnpinnedTabs",
		descriptionKey: "commandBar.actions.clearUnpinnedTabsDesc",
		icon: "trash",
		keywords: ["clear", "clear tabs", "archive tabs", "clean up", "ranger", "archiver"],
		shortcutId: "tab.clearUnpinned",
	},
	{
		id: "muteActiveTab",
		nameKey: "commandBar.actions.muteActiveTab",
		descriptionKey: "commandBar.actions.muteActiveTabDesc",
		icon: "mute",
		keywords: ["mute", "unmute", "mute tab", "silence tab", "audio"],
		shortcutId: "tab.mute",
	},
	{
		id: "bookmarkActivePage",
		nameKey: "commandBar.actions.bookmarkActivePage",
		descriptionKey: "commandBar.actions.bookmarkActivePageDesc",
		icon: "star",
		keywords: ["bookmark", "favorite", "add bookmark"],
		shortcutId: "tab.bookmark",
	},
	{
		id: "translatePage",
		nameKey: "commandBar.actions.translatePage",
		descriptionKey: "commandBar.actions.translatePageDesc",
		icon: "globe",
		keywords: ["translate", "translate page", "translation", "traduire"],
		shortcutId: "page.translate",
	},
	{
		id: "viewPageSource",
		nameKey: "commandBar.actions.viewPageSource",
		descriptionKey: "commandBar.actions.viewPageSourceDesc",
		icon: "code",
		keywords: ["source", "view source", "page source", "html"],
		shortcutId: "page.viewSource",
	},
	{
		id: "savePageAs",
		nameKey: "commandBar.actions.savePageAs",
		descriptionKey: "commandBar.actions.savePageAsDesc",
		icon: "download",
		keywords: ["save", "save page", "save as", "web archive", "pdf"],
		shortcutId: "page.save",
	},
	{
		id: "newTerminal",
		nameKey: "commandBar.actions.newTerminal",
		descriptionKey: "commandBar.actions.newTerminalDesc",
		icon: "terminal",
		keywords: ["terminal", "shell", "console", "command line", "zsh", "ligne de commande"],
		shortcutId: "terminal.newTab",
	},
	{
		id: "nextWaitingTerminal",
		nameKey: "commandBar.actions.nextWaitingTerminal",
		descriptionKey: "commandBar.actions.nextWaitingTerminalDesc",
		icon: "terminalNext",
		keywords: ["terminal", "agent", "waiting", "answer", "attente", "réponse", "claude"],
		shortcutId: "terminal.nextWaiting",
	},
	{
		id: "showChanges",
		nameKey: "commandBar.actions.showChanges",
		descriptionKey: "commandBar.actions.showChangesDesc",
		icon: "diff",
		keywords: ["changes", "diff", "git", "review", "modifications", "relire"],
		shortcutId: "terminal.showChanges",
	},
	{
		id: "newSplitView",
		nameKey: "commandBar.actions.newSplitView",
		descriptionKey: "commandBar.actions.newSplitViewDesc",
		icon: "split",
		keywords: ["split", "split view", "side by side", "vue partagée"],
		shortcutId: "split.new",
	},
	{
		id: "closeSplitView",
		nameKey: "commandBar.actions.closeSplitView",
		descriptionKey: "commandBar.actions.closeSplitViewDesc",
		icon: "unsplit",
		keywords: ["unsplit", "separate split", "close split", "separate tabs"],
		shortcutId: "split.close",
	},
] as const satisfies readonly CommandActionDefinition[];

const URL_PATTERN =
	/^(https?:\/\/|file:\/\/|about:|view-source:https?:\/\/|chrome-extension:\/\/|mailto:|data:)/i;
// An absolute filesystem path to a file, e.g. /Users/me/page.html. Requires at least one
// sub-directory and a file extension so it isn't confused with a `/`-prefixed history search
// (which is a single term, not a slash-separated path).
const FILE_PATH_PATTERN = /^\/[^?#]*\/[^/?#]+\.[A-Za-z0-9]+$/;
// A dotted host name in any script, its last label (not a number), then an optional port and path.
const DOMAIN_PATTERN = /^([^\s.:/?#@]+\.)+([^\s\d.:/?#@][^\s.:/?#@]*)\.?((:\d+)?([/?#].*)?)$/;
let topLevelDomains: Set<string> | undefined;
// Local hosts rarely serve https, so they go over http: localhost, mDNS (.local) and *.localhost names, IPv4
// addresses (loopback, private and link-local ranges included) and bracketed IPv6 literals ([fe80::1]:8080).
const LOCAL_HOST_PATTERN = /^(localhost|[^/:?#]+\.local(host)?|\d{1,3}(\.\d{1,3}){3}|\[[0-9a-f:.]+\])(:\d+)?(?=$|[/?#])/i;

/**
 * The command bar hands over the list from its own chunk, outside the chrome's first frame. Until then, a dotted
 * name ending in letters counts as an address.
 */
export function setTopLevelDomains(list: string): void {
	topLevelDomains = new Set(list.split(/\s/));
}

// As in Chrome, "node.js" is a search while "node.js/" or "intranet.corp:8443" is an address.
function isWebAddress(input: string): boolean {
	const match = DOMAIN_PATTERN.exec(input);
	if (!match) return false;
	if (match[3] || !topLevelDomains) return true;
	try {
		return topLevelDomains.has(new URL(`http://${match[2]}`).hostname);
	} catch {
		return false;
	}
}

// Live engine registry, mirrored from the `searchEngines` setting. Defaults to built-ins so the omnibox works before settings load.
let searchEngines: SearchEngine[] = BUILTIN_SEARCH_ENGINES.map((engine) => ({ ...engine }));

export function setSearchEngines(engines: SearchEngine[]): void {
	searchEngines = engines.length > 0 ? engines : BUILTIN_SEARCH_ENGINES.map((e) => ({ ...e }));
}

const ACTIONS_BY_KEYWORD = new Map<string, CommandActionId>();
const SCOPE_PREFIX_TO_SCOPE = Object.fromEntries(
	Object.entries(COMMAND_SCOPE_PREFIXES).map(([scope, prefix]) => [prefix, scope]),
) as Record<string, Exclude<CommandScope, "all">>;

for (const action of COMMAND_ACTIONS) {
	for (const keyword of action.keywords) {
		ACTIONS_BY_KEYWORD.set(keyword.toLowerCase(), action.id);
	}
}

function createBase<TType extends ParsedInput["type"]>(
	type: TType,
	query: string,
	scope: CommandScope,
): Extract<ParsedInput, { type: TType }> {
	return { type, query, scope } as Extract<ParsedInput, { type: TType }>;
}

function parseScope(trimmed: string, defaultScope: CommandScope): Pick<ParsedInputBase, "query" | "scope"> {
	const explicitScope = SCOPE_PREFIX_TO_SCOPE[trimmed[0] ?? ""];
	return explicitScope
		? { query: trimmed.slice(1).trimStart(), scope: explicitScope }
		: { query: trimmed, scope: defaultScope };
}

const SHORTCUT_MODIFIERS: Array<[string, string]> = [["Ctrl", "⌃"], ["Opt", "⌥"], ["Shift", "⇧"], ["Cmd", "⌘"]];
const SHORTCUT_KEYS: Record<string, string> = { Enter: "↩", Backspace: "⌫" };

/** "Cmd+Shift+T" as the Mac menus write it, "⇧⌘T": modifiers in ⌃⌥⇧⌘ order, then the key. */
export function formatShortcut(shortcut: string): string {
	const parts = shortcut.split("+");
	// "Cmd++" splits into a trailing empty pair: its key is "+" itself.
	const key = parts.at(-1) === "" ? "+" : parts.at(-1)!;
	const modifiers = new Set(parts.slice(0, key === "+" ? -2 : -1));
	return SHORTCUT_MODIFIERS.filter(([name]) => modifiers.has(name)).map(([, symbol]) => symbol).join("") + (SHORTCUT_KEYS[key] ?? key);
}

export function scopePrefix(scope: CommandScope): string {
	if (scope === "all") return "";
	return COMMAND_SCOPE_PREFIXES[scope];
}

/**
 * Parse a command bar input string into a structured result.
 * Priority: explicit scope, then URL, then action, then search query.
 */
export function parseInput(
	raw: string,
	defaultScope: CommandScope = "all",
): ParsedInput {
	// A bare absolute file path opens the local file. Checked before scope parsing so the
	// leading "/" isn't swallowed by the history-scope prefix.
	const trimmedRaw = raw.trim();
	if (defaultScope === "all" && FILE_PATH_PATTERN.test(trimmedRaw)) {
		return {
			...createBase("url", trimmedRaw, "all"),
			url: `file://${encodeURI(trimmedRaw)}`,
		};
	}

	const { query, scope } = parseScope(trimmedRaw, defaultScope);
	if (scope === "terminal") {
		return createBase("terminal", query, scope);
	}
	if (!query) {
		return createBase("search", "", scope);
	}

	// A data: URL is often typed with spaces in it: <h1>Hello there</h1>.
	if (scope === "all" && (!query.includes(" ") || /^data:/i.test(query))) {
		const url = URL_PATTERN.test(query)
			? query
			: LOCAL_HOST_PATTERN.test(query)
				? `http://${query}`
				: isWebAddress(query) ? `https://${query}` : "";
		if (url) return { ...createBase("url", query, scope), url };
	}

	// A bare single word ("zoom", "back") is a web search unless the `:` scope says
	// otherwise; multi-word aliases ("new tab") are unambiguous enough to run directly.
	const action = ACTIONS_BY_KEYWORD.get(query.toLowerCase());
	if (action && (scope === "action" || (scope === "all" && query.includes(" ")))) {
		return {
			...createBase("action", query, scope),
			action,
		};
	}

	// Explicit `:` scope with no matching command stays `type: "action"` (with no
	// `action` id) so it never falls back to a web search; executing it is a no-op.
	if (scope === "action") {
		return createBase("action", query, scope);
	}

	return createBase("search", query, scope);
}

export function getSearchEngineLabel(engine = "google"): string {
	return (findEngineById(searchEngines, engine) ?? searchEngines[0])?.name ?? "Search";
}

// A leading engine keyword (e.g. "yt cats") overrides the default engine for the remainder.
export function buildSearchURL(query: string, engine = "google"): string {
	const space = query.indexOf(" ");
	if (space > 0) {
		const keyworded = findEngineByKeyword(searchEngines, query.slice(0, space));
		if (keyworded) {
			return buildSearchURLFromTemplate(keyworded.urlTemplate, query.slice(space + 1).trim());
		}
	}
	const target = findEngineById(searchEngines, engine) ?? searchEngines[0];
	if (!target) return query;
	return buildSearchURLFromTemplate(target.urlTemplate, query);
}
