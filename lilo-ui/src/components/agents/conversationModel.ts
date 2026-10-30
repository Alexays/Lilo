// Reduces Agent Client Protocol `session/update` notifications into the thread a conversation renders.

export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string; uri?: string | null }
  | { type: "resource_link"; uri: string; name: string; title?: string | null }
  | { type: "resource"; resource: { uri: string; text?: string; blob?: string; mimeType?: string | null } };

export type ToolCallContent =
  | { type: "content"; content: ContentBlock }
  | { type: "diff"; path: string; oldText: string | null; newText: string }
  | { type: "terminal"; terminalId: string };

export type ToolKind =
  | "read"
  | "edit"
  | "delete"
  | "move"
  | "search"
  | "execute"
  | "think"
  | "fetch"
  | "switch_mode"
  | "other";

export type ToolCallStatus = "pending" | "in_progress" | "completed" | "failed";

export interface ToolCallLocation {
  path: string;
  line?: number | null;
}

export interface ToolCallFields {
  toolCallId: string;
  title?: string;
  kind?: ToolKind;
  status?: ToolCallStatus;
  content?: ToolCallContent[] | null;
  locations?: ToolCallLocation[] | null;
  rawInput?: unknown;
  rawOutput?: unknown;
}

export interface PlanEntry {
  content: string;
  priority: "high" | "medium" | "low";
  status: "pending" | "in_progress" | "completed";
}

export interface AvailableCommand {
  name: string;
  description: string;
  input?: { hint: string } | null;
}

export interface ConfigOption {
  id: string;
  name: string;
  category?: string | null;
  currentValue: string;
  options: { value: string; name: string; description?: string | null }[];
}

export type SessionUpdate =
  | {
      sessionUpdate: "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk";
      content: ContentBlock;
      messageId?: string | null;
    }
  | ({ sessionUpdate: "tool_call"; title: string } & ToolCallFields)
  | ({ sessionUpdate: "tool_call_update" } & ToolCallFields)
  | { sessionUpdate: "plan"; entries: PlanEntry[] }
  | { sessionUpdate: "available_commands_update"; availableCommands: AvailableCommand[] }
  | { sessionUpdate: "current_mode_update"; currentModeId: string }
  | { sessionUpdate: "config_option_update"; configOptions: ConfigOption[] }
  | { sessionUpdate: "session_info_update"; title?: string | null; updatedAt?: string | null }
  | { sessionUpdate: "usage_update"; used: number; size: number; cost?: unknown };

export interface PermissionOption {
  optionId: string;
  name: string;
  kind: "allow_once" | "allow_always" | "reject_once" | "reject_always";
}

export interface PermissionRequest {
  requestId: string | number;
  toolCall: ToolCallFields;
  options: PermissionOption[];
}

export interface ContextChip {
  label: string;
  uri: string;
}

export interface FileDiff {
  path: string;
  oldText: string | null;
  newText: string;
  added: number;
  removed: number;
}

export interface UserMessageItem {
  kind: "user";
  id: number;
  messageId: string | null;
  text: string;
  context: ContextChip[];
}

export interface TextItem {
  kind: "agent" | "thought";
  id: number;
  messageId: string | null;
  text: string;
}

export interface ImageRef {
  /** A data: URL, or a local file's path or file: URL the view resolves against the project. */
  src: string;
  alt: string;
}

/** A picture the agent shows in its reply. */
export interface ImageItem extends ImageRef {
  kind: "image";
  id: number;
  messageId: string | null;
}

export interface ToolCallItem {
  kind: "toolCall";
  id: number;
  toolCallId: string;
  title: string;
  toolKind: ToolKind;
  status: ToolCallStatus;
  diffs: FileDiff[];
  output: string;
  /** Pictures the call returned, such as a browser screenshot. */
  images: ImageRef[];
  locations: ToolCallLocation[];
  rawInput: unknown;
  /** From the call's raw output, when the agent reports one. */
  exitCode: number | null;
  /** Milliseconds since 1970, known only for calls seen live (not replayed). */
  startedAt: number | null;
  endedAt: number | null;
}

/** Closes a turn: its footer. `durationMs` is known only when the whole turn was seen live. */
export interface TurnEndItem {
  kind: "turnEnd";
  id: number;
  stopReason: string;
  durationMs: number | null;
}

export interface PlanItem {
  kind: "plan";
  id: number;
  entries: PlanEntry[];
}

export interface PermissionItem {
  kind: "permission";
  id: number;
  requestId: string | number;
  toolCall: ToolCallFields;
  options: PermissionOption[];
  answer: string | null;
}

export interface NoticeItem {
  kind: "notice";
  id: number;
  text: string;
}

export type ThreadItem =
  | UserMessageItem
  | TextItem
  | ImageItem
  | ToolCallItem
  | TurnEndItem
  | PlanItem
  | PermissionItem
  | NoticeItem;

export interface ConversationState {
  items: ThreadItem[];
  title: string | null;
  modeId: string | null;
  configOptions: ConfigOption[];
  commands: AvailableCommand[];
  usage: { used: number; size: number } | null;
  toolCalls: Map<string, ToolCallItem>;
  plan: PlanItem | null;
  // Unechoed rest of the locally shown prompt; its attached context is skipped until another kind of update arrives.
  pendingEcho: string | null;
  /** When the running turn's first item arrived live; null between turns or when it was replayed. */
  turnStartedAt: number | null;
  nextId: number;
}

export function emptyConversation(): ConversationState {
  return {
    items: [],
    title: null,
    modeId: null,
    configOptions: [],
    commands: [],
    usage: null,
    toolCalls: new Map(),
    plan: null,
    pendingEcho: null,
    turnStartedAt: null,
    nextId: 1,
  };
}

function countLines(text: string): number {
  if (!text) return 0;
  let lines = 1;
  for (let i = text.indexOf("\n"); i !== -1; i = text.indexOf("\n", i + 1)) lines++;
  return text.endsWith("\n") ? lines - 1 : lines;
}

/** Lines only in `newText` and only in `oldText`, compared as multisets: order-blind but linear. */
export function diffStats(oldText: string | null, newText: string): { added: number; removed: number } {
  if (!oldText) return { added: countLines(newText), removed: 0 };
  const remaining = new Map<string, number>();
  const oldLines = oldText.split("\n");
  if (oldText.endsWith("\n")) oldLines.pop();
  for (const line of oldLines) remaining.set(line, (remaining.get(line) ?? 0) + 1);
  const newLines = newText ? newText.split("\n") : [];
  if (newText.endsWith("\n")) newLines.pop();
  let added = 0;
  for (const line of newLines) {
    const count = remaining.get(line);
    if (count) remaining.set(line, count - 1);
    else added++;
  }
  let removed = 0;
  for (const count of remaining.values()) removed += count;
  return { added, removed };
}

/** What the chrome can draw of a local file: the image types `conversation-file/` serves. */
export const IMAGE_FILE = /\.(png|jpe?g|gif|webp|svg|heic|avif)$/i;

function setContent(call: ToolCallItem, content: ToolCallContent[]): void {
  call.diffs = [];
  call.output = "";
  call.images = [];
  for (const entry of content) {
    if (entry.type === "diff") {
      call.diffs.push({ path: entry.path, oldText: entry.oldText, newText: entry.newText, ...diffStats(entry.oldText, entry.newText) });
    } else if (entry.type === "content" && entry.content.type === "text") {
      call.output = call.output ? `${call.output}\n${entry.content.text}` : entry.content.text;
    } else if (entry.type === "content" && entry.content.type === "image") {
      call.images.push({ src: `data:${entry.content.mimeType};base64,${entry.content.data}`, alt: call.title });
    }
  }
}

function applyToolCall(state: ConversationState, update: ToolCallFields, receivedAt: number | null): void {
  let call = state.toolCalls.get(update.toolCallId);
  if (!call) {
    call = {
      kind: "toolCall",
      id: state.nextId++,
      toolCallId: update.toolCallId,
      title: "",
      toolKind: "other",
      status: "pending",
      diffs: [],
      output: "",
      images: [],
      locations: [],
      rawInput: null,
      exitCode: null,
      startedAt: receivedAt,
      endedAt: null,
    };
    state.toolCalls.set(update.toolCallId, call);
    state.items.push(call);
  }
  if (update.title != null) call.title = update.title;
  if (update.kind != null) call.toolKind = update.kind;
  if (update.status != null) call.status = update.status;
  if (update.content != null) setContent(call, update.content);
  if (update.locations != null) call.locations = update.locations;
  if (update.rawInput != null) call.rawInput = update.rawInput;
  if (update.rawOutput != null && typeof update.rawOutput === "object") {
    const raw = update.rawOutput as Record<string, unknown>;
    const code = raw.exitCode ?? raw.exit_code;
    if (typeof code === "number") call.exitCode = code;
  }
  if (receivedAt !== null && call.endedAt === null && (call.status === "completed" || call.status === "failed")) {
    call.endedAt = receivedAt;
  }
}

function applyChunk(
  state: ConversationState,
  kind: "user" | "agent" | "thought",
  content: ContentBlock,
  messageId: string | null,
): void {
  if (kind === "user" && state.pendingEcho !== null) {
    if (content.type !== "text") return;
    if (state.pendingEcho.startsWith(content.text)) {
      state.pendingEcho = state.pendingEcho.slice(content.text.length);
      return;
    }
    state.pendingEcho = null;
  }
  const last = state.items[state.items.length - 1];
  const item = last?.kind === kind && last.messageId === messageId ? last : null;
  if (content.type === "text") {
    if (item) item.text += content.text;
    else pushText(state, kind, messageId, content.text);
  } else if (kind === "agent" && content.type === "image") {
    state.items.push({ kind: "image", id: state.nextId++, messageId, src: `data:${content.mimeType};base64,${content.data}`, alt: "" });
  } else if (kind === "agent" && content.type === "resource_link" && IMAGE_FILE.test(content.uri) && /^(file:|\/)/.test(content.uri)) {
    state.items.push({ kind: "image", id: state.nextId++, messageId, src: content.uri, alt: content.title || content.name || "" });
  } else if (kind === "user" && (content.type === "resource_link" || content.type === "resource")) {
    const chip =
      content.type === "resource_link"
        ? { label: content.title || content.name || content.uri, uri: content.uri }
        : { label: content.resource.uri, uri: content.resource.uri };
    const user = (item ?? pushText(state, kind, messageId, "")) as UserMessageItem;
    user.context.push(chip);
  }
}

function pushText(
  state: ConversationState,
  kind: "user" | "agent" | "thought",
  messageId: string | null,
  text: string,
): UserMessageItem | TextItem {
  const item: UserMessageItem | TextItem =
    kind === "user"
      ? { kind, id: state.nextId++, messageId, text, context: [] }
      : { kind, id: state.nextId++, messageId, text };
  state.items.push(item);
  return item;
}

const ITEM_UPDATES = new Set([
  "user_message_chunk",
  "agent_message_chunk",
  "agent_thought_chunk",
  "tool_call",
  "tool_call_update",
  "plan",
]);

/**
 * Applies one `session/update` payload in place; unknown kinds are ignored. `receivedAt` is set for an
 * update that arrives live, null for one replayed from the log.
 */
export function applyUpdate(state: ConversationState, update: SessionUpdate, receivedAt: number | null = null): ConversationState {
  if (update.sessionUpdate !== "user_message_chunk") state.pendingEcho = null;
  // Only updates that draw something start a turn: usage or command lists also arrive between turns.
  if (receivedAt !== null && state.turnStartedAt === null && ITEM_UPDATES.has(update.sessionUpdate)) {
    state.turnStartedAt = receivedAt;
  }
  switch (update.sessionUpdate) {
    case "user_message_chunk":
      applyChunk(state, "user", update.content, update.messageId ?? null);
      break;
    case "agent_message_chunk":
      applyChunk(state, "agent", update.content, update.messageId ?? null);
      break;
    case "agent_thought_chunk":
      applyChunk(state, "thought", update.content, update.messageId ?? null);
      break;
    case "tool_call":
    case "tool_call_update":
      applyToolCall(state, update, receivedAt);
      break;
    case "plan":
      if (state.plan) state.plan.entries = update.entries;
      else {
        state.plan = { kind: "plan", id: state.nextId++, entries: update.entries };
        state.items.push(state.plan);
      }
      break;
    case "available_commands_update":
      state.commands = update.availableCommands;
      break;
    case "current_mode_update":
      state.modeId = update.currentModeId;
      break;
    case "config_option_update":
      state.configOptions = update.configOptions;
      break;
    case "session_info_update":
      if (update.title !== undefined) state.title = update.title;
      break;
    case "usage_update":
      state.usage = { used: update.used, size: update.size };
      break;
  }
  return state;
}

export function applyUpdates(state: ConversationState, updates: SessionUpdate[], receivedAt: number | null = null): ConversationState {
  for (const update of updates) applyUpdate(state, update, receivedAt);
  return state;
}

/** Shows a locally sent prompt right away; the agent's echo of the same text is then skipped. */
export function addUserPrompt(
  state: ConversationState,
  text: string,
  context: ContextChip[],
  receivedAt: number | null = null,
): ConversationState {
  state.items.push({ kind: "user", id: state.nextId++, messageId: null, text, context });
  state.pendingEcho = text;
  if (receivedAt !== null) state.turnStartedAt ??= receivedAt;
  return state;
}

/** Closes the running turn with its footer; a second end in a row adds nothing. */
export function endTurn(state: ConversationState, stopReason: string, receivedAt: number | null = null): ConversationState {
  const started = state.turnStartedAt;
  state.turnStartedAt = null;
  if (state.items[state.items.length - 1]?.kind === "turnEnd") return state;
  state.items.push({
    kind: "turnEnd",
    id: state.nextId++,
    stopReason,
    durationMs: started !== null && receivedAt !== null ? receivedAt - started : null,
  });
  return state;
}

export function addPermissionRequest(state: ConversationState, request: PermissionRequest): ConversationState {
  state.items.push({
    kind: "permission",
    id: state.nextId++,
    requestId: request.requestId,
    toolCall: request.toolCall,
    options: request.options,
    answer: null,
  });
  return state;
}

export function resolvePermission(
  state: ConversationState,
  requestId: string | number,
  optionId: string,
): ConversationState {
  for (let i = state.items.length - 1; i >= 0; i--) {
    const item = state.items[i];
    if (item.kind === "permission" && item.requestId === requestId) {
      item.answer = optionId;
      break;
    }
  }
  return state;
}

export function addNotice(state: ConversationState, text: string): ConversationState {
  state.items.push({ kind: "notice", id: state.nextId++, text });
  return state;
}
