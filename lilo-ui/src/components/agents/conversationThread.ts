import type { BridgeConversationOpened, BridgeConversationUpdate, BridgePermissionOption } from "../../lib/bridge/protocol";
import {
	addNotice,
	addPermissionRequest,
	addQuestion,
	addUserPrompt,
	applyUpdate,
	configOptions,
	type ContextChip,
	type ConversationState,
	emptyConversation,
	endTurn,
	resolvePermission,
	resolveQuestion,
	type QuestionAnswer,
	type SessionUpdate,
	type ToolCallFields,
} from "./conversationModel";

/** What an agent's terminal sign-in asks, read from the screen of the terminal Lilo runs it on. */
export interface SignInScreen {
	lines: string[];
	question: string;
	choices: { key: string; label: string }[];
}

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
	/** A sign-in the sent prompt waits on: in a terminal, or through the agent. `screen` is set while the thread draws the terminal's. */
	signingIn: { terminal: boolean; screen: SignInScreen | null } | null;
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
		signingIn: null,
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
		case "lilo_question":
			addQuestion(thread, String(update.requestId), String(update.message ?? ""), update.requestedSchema, typeof update.toolCallId === "string" ? update.toolCallId : undefined);
			break;
		case "lilo_permission_resolved":
			// A question settles with the form's answer; one the agent dropped settles as cancelled.
			if (update.answer || thread.items.some((item) => item.kind === "question" && item.requestId === String(update.requestId)))
				resolveQuestion(thread, String(update.requestId), (update.answer as QuestionAnswer | undefined) ?? { action: "cancel" });
			else resolvePermission(thread, String(update.requestId), typeof update.optionId === "string" ? update.optionId : "");
			break;
		case "lilo_notice":
			addNotice(thread, String(update.notice ?? ""));
			if (update.notice === "signedIn") conversation.signingIn = null;
			break;
		case "lilo_undo":
			if (update.ok) conversation.undone.add(String(update.path));
			break;
		case "lilo_error":
			// A failed turn drops the prompts queued behind it: they no longer wait for anything.
			for (const item of thread.items) if (item.kind === "user") delete item.queued;
			thread.turnStartedAt = null;
			conversation.error = String(update.message ?? "");
			conversation.signingIn = null;
			break;
		case "lilo_signing_in":
			conversation.signingIn = { terminal: update.terminal === true, screen: null };
			conversation.error = null;
			conversation.authMethods = [];
			break;
		case "lilo_sign_in_screen":
			if (conversation.signingIn) {
				conversation.signingIn.screen = {
					lines: (update.lines as string[] | undefined) ?? [],
					question: String(update.question ?? ""),
					choices: (update.choices as SignInScreen["choices"] | undefined) ?? [],
				};
			}
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
			conversation.signingIn = null;
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
			if (Array.isArray(update.configOptions)) thread.configOptions = configOptions(update.configOptions);
			break;
		}
		default:
			// The agent answers again: any sign-in it waited on is over.
			conversation.signingIn = null;
			applyUpdate(thread, update as unknown as SessionUpdate, receivedAt ?? stampOf(update));
	}
}
