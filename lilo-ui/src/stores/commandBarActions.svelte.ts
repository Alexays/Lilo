import { setTabPosition } from "./tabLayout.svelte";
import {
	chromeActions,
	spaceActions,
	tabActions,
	terminalActions,
} from "../lib/bridge/actions";
import { optimisticallyActivateTab } from "./sidebar.svelte";
import {
	type CommandActionId,
	type ParsedInput,
	buildSearchURL,
} from "../lib/inputParser";
import {
	openAddEditor,
	openDownloadsPanel,
	openHistoryPage,
	openProcessManager,
	openSettings,
} from "./panels.svelte";
import { getActiveTab } from "./tabs.svelte";
import { openLockPanel } from "./folderLock.svelte";
import { startOnboarding } from "./onboarding.svelte";
import type { CommandResult } from "./commandBarSearch.svelte";

const ACTION_HANDLERS: Record<CommandActionId, () => void> = {
	createTab: () => tabActions.create(),
	closeActiveTab: () => {
		const activeTab = getActiveTab();
		if (activeTab) tabActions.close(activeTab.id);
	},
	openSettings: () => openSettings(),
	openFeatureFlags: () => openSettings("advanced"),
	openProcessManager,
	replayOnboarding: () => startOnboarding("full"),
	createSpace: openAddEditor,
	createPrivateSpace: () => spaceActions.create({ isPrivate: true }),
	toggleSidebar: () => chromeActions.toggleSidebar(),
	moveTabsLeft: () => setTabPosition("left"),
	moveTabsRight: () => setTabPosition("right"),
	moveTabsTop: () => setTabPosition("top"),
	moveTabsBottom: () => setTabPosition("bottom"),
	reloadPage: () => tabActions.reload(),
	goBack: () => tabActions.goBack(),
	goForward: () => tabActions.goForward(),
	stopLoading: () => tabActions.stopLoading(),
	zoomIn: () => tabActions.zoomIn(),
	zoomOut: () => tabActions.zoomOut(),
	resetZoom: () => tabActions.zoomReset(),
	captureFullPage: () => tabActions.screenshotPage("full"),
	captureArea: () => tabActions.screenshotPage("region"),
	findInPage: () => tabActions.showFindBar(),
	toggleReader: () => tabActions.toggleReader(),
	copyPageURL: () => tabActions.copyPageURL(),
	togglePinActiveTab: () => tabActions.togglePinActive(),
	duplicateActiveTab: () => tabActions.duplicateActive(),
	showDownloads: openDownloadsPanel,
	showHistory: () => openHistoryPage(),
	openPasswordsApp: () => tabActions.openPasswordsApp(),
	reopenClosedTab: () => tabActions.restoreClosed(),
	clearUnpinnedTabs: () => tabActions.clearUnpinned(),
	muteActiveTab: () => {
		const activeTab = getActiveTab();
		if (activeTab) tabActions.setMuted(activeTab.id, !activeTab.isMuted);
	},
	bookmarkActivePage: () => {
		const activeTab = getActiveTab();
		if (activeTab) tabActions.setBookmarked(activeTab.id, !activeTab.isBookmarked);
	},
	translatePage: () => tabActions.translatePage(),
	viewPageSource: () => tabActions.viewPageSource(),
	savePageAs: () => tabActions.savePageAs(),
	newSplitView: () => tabActions.newSplitView(),
	closeSplitView: () => tabActions.closeSplitView(),
	newTerminal: () => tabActions.newTerminal(),
	nextWaitingTerminal: () => terminalActions.showNextWaiting(),
	showChanges: () => terminalActions.showChanges(),
};

function navigateTo(url?: string, typed?: boolean): void {
	if (url) tabActions.navigate(url, typed);
}

export function executeResult(
	result: CommandResult,
	onFinish: (closeBlankTab?: boolean) => void,
): void {
	if (result.kind === "action") {
		ACTION_HANDLERS[result.payload.action as CommandActionId]();
	} else if (result.kind === "terminal") {
		terminalActions.run(result.payload.command as string, false);
	} else if (result.kind === "terminalTab") {
		terminalActions.reveal(result.payload.tabId as string);
	} else if (result.kind === "closedTerminal") {
		terminalActions.restoreClosed(result.payload.index as number);
	} else if (result.kind === "archivedTab") {
		tabActions.restoreArchived([result.payload.id as string]);
	} else if (result.kind === "clearArchive") {
		tabActions.clearArchived();
	} else if (result.kind === "showAllHistory") {
		openHistoryPage({ query: result.payload.query as string });
	} else if (result.kind === "tab") {
		optimisticallyActivateTab(result.payload.tabId as string);
		tabActions.switchTo(result.payload.tabId as string);
	} else if (
		result.kind === "bookmark" &&
		typeof result.payload.tabId === "string"
	) {
		optimisticallyActivateTab(result.payload.tabId);
		tabActions.switchTo(result.payload.tabId);
	} else if (result.kind === "lockedFolder") {
		openLockPanel(result.payload.folderId as string, "unlock");
	} else if (result.kind === "space") {
		spaceActions.switchTo(result.payload.spaceId as string);
	} else if (result.kind === "moveToSpace") {
		const tabId = (result.payload.tabId as string | undefined) ?? getActiveTab()?.id;
		if (tabId) spaceActions.moveTabToSpace(tabId, result.payload.spaceId as string);
	} else {
		navigateTo(result.url, result.payload.typed === true);
	}
	// Switching to or opening another tab leaves the blank one behind: close it.
	onFinish(
		result.kind === "tab" || result.kind === "bookmark" || result.kind === "terminal" ||
			result.kind === "terminalTab" || result.kind === "closedTerminal" || result.kind === "archivedTab" ||
			result.kind === "space",
	);
}

export function executeResultInNewTab(
	result: CommandResult,
	onFinish: (closeBlankTab?: boolean) => void,
): void {
	if (result.kind === "action") {
		ACTION_HANDLERS[result.payload.action as CommandActionId]();
	} else if (result.kind === "terminal") {
		terminalActions.run(result.payload.command as string, true);
	} else if (result.kind === "terminalTab") {
		terminalActions.reveal(result.payload.tabId as string);
	} else if (result.kind === "closedTerminal") {
		terminalActions.restoreClosed(result.payload.index as number);
	} else if (result.kind === "archivedTab") {
		tabActions.restoreArchived([result.payload.id as string]);
	} else if (result.kind === "tab") {
		tabActions.create(result.url);
	} else if (result.kind === "lockedFolder") {
		openLockPanel(result.payload.folderId as string, "unlock");
	} else if (result.url) {
		tabActions.create(result.url, result.payload.typed === true);
	} else {
		return;
	}
	onFinish(false);
}

export function executeRawQuery(
	parsed: ParsedInput,
	searchEngine: string,
	onFinish: (closeBlankTab?: boolean) => void,
): void {
	if (parsed.type === "terminal") {
		if (!parsed.query) return;
		terminalActions.run(parsed.query, false);
		onFinish(true);
		return;
	}
	// Nothing archived matched: the archive is not a search box.
	if (parsed.scope === "archive") return;
	if (parsed.type === "action") {
		// A free-form `:` query (no `action` id) matches no known command and is a no-op.
		if (parsed.action) ACTION_HANDLERS[parsed.action]();
	} else if (parsed.scope !== "all") {
		// Scoped search with no match: fall back to web search. The `action` scope
		// cannot reach here: parseInput always types it as "action", handled above.
		// An empty scoped query has nothing to run and keeps the bar open.
		if (!parsed.query) return;
		navigateTo(buildSearchURL(parsed.query, searchEngine));
	} else if (parsed.type === "url") {
		navigateTo(parsed.url, true);
	} else {
		navigateTo(buildSearchURL(parsed.query, searchEngine));
	}
	onFinish(false);
}

export function executeRawQueryInNewTab(
	parsed: ParsedInput,
	searchEngine: string,
	onFinish: (closeBlankTab?: boolean) => void,
): void {
	if (parsed.type === "action") {
		if (parsed.action) ACTION_HANDLERS[parsed.action]();
		onFinish(false);
		return;
	}

	if (parsed.type === "terminal") {
		if (!parsed.query) return;
		terminalActions.run(parsed.query, true);
		onFinish(false);
		return;
	}

	if (parsed.scope === "archive") return;

	if (parsed.scope !== "all") {
		// Scoped search with no match: fall back to web search. The `action` scope
		// cannot reach here: parseInput always types it as "action", handled above.
		// An empty scoped query has nothing to run and keeps the bar open.
		if (!parsed.query) return;
		tabActions.create(buildSearchURL(parsed.query, searchEngine));
		onFinish(false);
		return;
	}

	if (parsed.type === "url") tabActions.create(parsed.url, true);
	else tabActions.create(buildSearchURL(parsed.query, searchEngine));
	onFinish(false);
}
