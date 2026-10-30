import type { BridgeConversationOpened, BridgeConversationUpdate, BridgePermissionOption } from "../../lib/bridge/protocol";
import {
	addNotice,
	addPermissionRequest,
	addUserPrompt,
	applyUpdate,
	type ConfigOption,
	type ContextChip,
	type ConversationState,
	emptyConversation,
	endTurn,
	resolvePermission,
	type SessionUpdate,
	type ToolCallFields,
} from "./conversationModel";

export interface SessionMode {
	id: string;
	name: string;
	description?: string | null;
}

/** A conversation the chrome shows: its thread, rebuilt from the log Lilo replays, then kept up to date. */
export interface OpenConversation {
	tabId: string;
	agentId: string;
	cwd: string;
	thread: ConversationState;
	modes: SessionMode[];
	/** Per prompt sent, in order: whether "Restore to here" can bring its files back. */
	checkpoints: boolean[];
	/** Files put back with Undo, by path. */
	undone: Set<string>;
	queued: number;
	error: string | null;
	/** The agent's sign-in methods, offered after it asked for one. */
	authMethods: { id: string; name: string; description: string | null }[];
	/** Prompts already drawn by `addLocalPrompt`, oldest first: Lilo's echo of each is skipped. */
	localPrompts: string[];
}

export function openConversation(data: BridgeConversationOpened, later: BridgeConversationUpdate[]): OpenConversation {
	const conversation: OpenConversation = {
		tabId: data.tabId,
		agentId: data.agentId,
		cwd: data.cwd,
		thread: emptyConversation(),
		modes: [],
		checkpoints: [],
		undone: new Set(),
		queued: 0,
		error: data.error ?? null,
		authMethods: [],
		localPrompts: [],
	};
	for (const update of data.updates) apply(conversation, update);
	conversation.checkpoints = data.checkpoints.length ? data.checkpoints : conversation.checkpoints;
	const now = Date.now();
	for (const update of later) apply(conversation, update, now);
	return conversation;
}

/** Draws a prompt on the frame it is sent, before Lilo echoes it back; returns its item id. */
export function addLocalPrompt(conversation: OpenConversation, text: string, context: ContextChip[]): number {
	addUserPrompt(conversation.thread, text, context, Date.now());
	conversation.localPrompts.push(text);
	return conversation.thread.items[conversation.thread.items.length - 1].id;
}

/** When Lilo logged a prompt or a turn's end: what times turns replayed from disk. */
function stampOf(update: BridgeConversationUpdate): number | null {
	return typeof update.at === "number" ? update.at : null;
}

/** `receivedAt` is set for an update that arrives live, null for one replayed from the log. */
export function apply(conversation: OpenConversation, update: BridgeConversationUpdate, receivedAt: number | null = null): void {
	const thread = conversation.thread;
	switch (update.sessionUpdate) {
		case "lilo_user": {
			const text = String(update.text ?? "");
			if (conversation.localPrompts[0] === text) conversation.localPrompts.shift();
			else addUserPrompt(thread, text, (update.context as ContextChip[] | undefined) ?? [], receivedAt ?? stampOf(update));
			conversation.checkpoints.push(false);
			break;
		}
		case "lilo_permission":
			addPermissionRequest(thread, {
				requestId: String(update.requestId),
				toolCall: update.toolCall as ToolCallFields,
				options: update.options as BridgePermissionOption[],
			});
			break;
		case "lilo_permission_resolved":
			resolvePermission(thread, String(update.requestId), typeof update.optionId === "string" ? update.optionId : "");
			break;
		case "lilo_notice":
			addNotice(thread, String(update.notice ?? ""));
			break;
		case "lilo_undo":
			if (update.ok) conversation.undone.add(String(update.path));
			break;
		case "lilo_error":
			conversation.error = String(update.message ?? "");
			break;
		case "lilo_checkpoint":
			conversation.checkpoints[Number(update.index)] = true;
			break;
		case "lilo_auth":
			conversation.authMethods = update.methods as OpenConversation["authMethods"];
			break;
		case "lilo_turn_end":
			endTurn(thread, String(update.stopReason ?? "end_turn"), receivedAt ?? stampOf(update));
			conversation.error = null;
			conversation.authMethods = [];
			break;
		case "lilo_queued":
			conversation.queued = Number(update.count ?? 0);
			break;
		case "lilo_session": {
			const modes = update.modes as { currentModeId?: string; availableModes?: SessionMode[] } | undefined;
			if (modes) {
				conversation.modes = modes.availableModes ?? [];
				thread.modeId = modes.currentModeId ?? thread.modeId;
			}
			if (Array.isArray(update.configOptions)) thread.configOptions = update.configOptions as ConfigOption[];
			break;
		}
		default:
			applyUpdate(thread, update as unknown as SessionUpdate, receivedAt);
	}
}
