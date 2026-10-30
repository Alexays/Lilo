import { on, postMessage } from "../lib/bridge";
import type {
	BridgeAgentInfo,
	BridgeConversationState,
	BridgeConversationSummary,
	BridgeConversationUpdate,
} from "../lib/bridge/protocol";
import type { ContextChip } from "../components/agents/conversationModel";
import type { OpenConversation } from "../components/agents/conversationThread";

export type { OpenConversation, SessionMode } from "../components/agents/conversationThread";

// The thread logic loads with the first conversation shown, never in the chrome's first frame.
let thread: typeof import("../components/agents/conversationThread") | null = null;
/** Updates that arrive while a conversation's log waits for the thread logic to load. */
const pending = new Map<string, BridgeConversationUpdate[]>();

let _summaries = $state.raw<BridgeConversationSummary[]>([]);
let _agents = $state.raw<BridgeAgentInfo[]>([]);
let _projects = $state.raw<string[]>([]);
let _home = $state.raw("");
let _chosenProject = $state.raw<string | null>(null);
let _askOpen = $state(false);
let _askSelection = $state.raw("");
let _files = $state.raw<{ cwd: string; query: string; files: string[] }>({ cwd: "", query: "", files: [] });
let fileSearch: ReturnType<typeof setTimeout> | undefined;
/** Bumped at most once per frame when an open conversation changes: its thread is mutated in place. */
let _version = $state(0);
const open = new Map<string, OpenConversation>();
let bumpScheduled = false;

function bump(): void {
	if (bumpScheduled) return;
	bumpScheduled = true;
	requestAnimationFrame(() => {
		bumpScheduled = false;
		_version++;
	});
}

export function initConversationsStore(): void {
	on("conversationsChanged", (data) => { _summaries = data.conversations; });
	on("agentCatalog", (data) => {
		_agents = data.agents;
		_projects = data.projects;
		_home = data.home;
	});
	on("conversationProjectChosen", (data) => { _chosenProject = data.path; });
	on("conversationFiles", (data) => { _files = data; });
	on("openAskBar", (data) => {
		_askSelection = data.selection;
		_askOpen = true;
	});
	on("conversationOpened", async (data) => {
		pending.set(data.tabId, []);
		thread ??= await import("../components/agents/conversationThread");
		open.set(data.tabId, thread.openConversation(data, pending.get(data.tabId) ?? []));
		pending.delete(data.tabId);
		bump();
	});
	on("conversationUpdate", (data) => {
		const waiting = pending.get(data.tabId);
		if (waiting) return void waiting.push(data.update);
		const conversation = open.get(data.tabId);
		if (!conversation || !thread) return;
		thread.apply(conversation, data.update, Date.now());
		bump();
	});
}

/** Draws a prompt right away, ahead of Lilo's echo; returns its item id, or null while the thread loads. */
export function addLocalPrompt(tabId: string, text: string, context: ContextChip[]): number | null {
	const conversation = open.get(tabId);
	if (!conversation || !thread) return null;
	const id = thread.addLocalPrompt(conversation, text, context);
	// Not coalesced: the prompt shows on the frame it was sent.
	_version++;
	return id;
}

/** Asks Lilo for a conversation's log; `hideConversation` stops its updates when it leaves the screen. */
export function showConversation(tabId: string): void {
	postMessage("showConversation", { tabId, visible: true });
}

export function hideConversation(tabId: string): void {
	open.delete(tabId);
	postMessage("showConversation", { tabId, visible: false });
}

/** Read `getConversationVersion()` in the same reactive scope to re-render as the thread grows. */
export const getOpenConversation = (tabId: string): OpenConversation | undefined => open.get(tabId);
export const getConversationVersion = (): number => _version;
export const getConversationSummaries = (): BridgeConversationSummary[] => _summaries;
export const getConversationSummary = (tabId: string): BridgeConversationSummary | undefined =>
	_summaries.find((summary) => summary.tabId === tabId);
export const getConversationState = (tabId: string): BridgeConversationState =>
	getConversationSummary(tabId)?.state ?? "idle";
export const getAgents = (): BridgeAgentInfo[] => _agents;
export const getAgent = (id: string): BridgeAgentInfo | undefined => _agents.find((agent) => agent.id === id);
export const getProjects = (): string[] => _projects;
/** A project's name as the pickers show it: its folder, or ~ for the home folder. */
export const projectName = (path: string): string => (path === _home ? "~" : path.split("/").filter(Boolean).pop() ?? path);
export const getChosenProject = (): string | null => _chosenProject;
export const clearChosenProject = (): void => { _chosenProject = null; };
export const isAskBarOpen = (): boolean => _askOpen;
/** The bar opened from the chrome (the New Tab row) has no page selection to offer. */
export const openAskBar = (): void => {
	_askSelection = "";
	_askOpen = true;
};
/** Asks for the project's files matching `query`, once typing pauses: `getProjectFiles` gets the answer. */
export function searchProjectFiles(cwd: string, query: string): void {
	clearTimeout(fileSearch);
	fileSearch = setTimeout(() => postMessage("searchConversationFiles", { cwd, query }), 60);
}

/** The last answer to `searchProjectFiles`, for the query it was asked with. */
export const getProjectFiles = (): { cwd: string; query: string; files: string[] } => _files;

/** The page's selected text when the bar opened, empty when there was none. */
export const getAskSelection = (): string => _askSelection;
export const closeAskBar = (): void => { _askOpen = false; };
/** Conversations waiting on an answer, for the Agents badge. */
export const getWaitingCount = (): number => _summaries.filter((summary) => summary.permission).length;
