// Reduces Agent Client Protocol `session/update` notifications into the thread a conversation renders.

export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string; uri?: string | null }
  | { type: "resource_link"; uri: string; name: string; title?: string | null }
  | { type: "resource"; resource: { uri: string; text?: string; blob?: string; mimeType?: string | null } };

/** ACP v2's diff: the files changed, and a patch of them when the agent has one. */
export interface DiffV2 {
  type: "diff";
  changes: { operation: string; path: string; oldPath?: string }[];
  patch?: { format: string; text: string } | null;
}

export type ToolCallContent =
  | { type: "content"; content: ContentBlock }
  | { type: "diff"; path: string; oldText: string | null; newText: string }
  | DiffV2
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

/** What a session still runs after its turn, in a v2 `state_update`. */
export type BackgroundWork = { type: "terminal"; terminalId: string } | { type: "tool_call"; toolCallId: string } | { type: string };

export interface ToolCallLocation {
  path: string;
  line?: number | null;
}

export interface ToolCallFields {
  toolCallId: string;
  /** v2: the tool's own name. */
  name?: string | null;
  title?: string;
  kind?: ToolKind;
  /** v2 adds `cancelled` and `paused`. */
  status?: ToolCallStatus | "cancelled" | "paused";
  content?: ToolCallContent[] | null;
  locations?: ToolCallLocation[] | null;
  rawInput?: unknown;
  rawOutput?: unknown;
  _meta?: Record<string, unknown> | null;
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

/** v2 names the option `configId`, which the thread reads as `id`, and can group its values. */
export interface ConfigOption {
  id: string;
  name: string;
  category?: string | null;
  currentValue: string;
  options: { value: string; name: string; description?: string | null }[];
}

/** Lilo tags an update of a v2 sub-agent's own session with that session. */
type Routed = { childSession?: string };

export type SessionUpdate = Routed &
  (
  | {
      sessionUpdate: "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk";
      content: ContentBlock;
      messageId?: string | null;
      _meta?: Record<string, unknown> | null;
    }
  | { sessionUpdate: "user_message" | "agent_message" | "agent_thought"; messageId: string; content?: ContentBlock[] | null }
  | ({ sessionUpdate: "tool_call"; title: string } & ToolCallFields)
  | ({ sessionUpdate: "tool_call_update" } & ToolCallFields)
  | { sessionUpdate: "tool_call_content_chunk"; toolCallId: string; content: ToolCallContent }
  | {
      sessionUpdate: "state_update";
      state: string;
      stopReason?: string | null;
      background?: BackgroundWork[] | null;
    }
  | {
      sessionUpdate: "terminal_update";
      terminalId: string;
      output?: { data: string } | null;
      exitStatus?: { exitCode?: number | null; signal?: string | null } | null;
    }
  | { sessionUpdate: "terminal_output_chunk"; terminalId: string; data: string }
  | { sessionUpdate: "subagent_update"; sessionId: string; title?: string | null; description?: string | null; state?: { state: string; stopReason?: string | null } | null }
  | { sessionUpdate: "session_message"; messageId: string; senderSessionId?: string | null; recipientSessionId?: string | null; content?: ContentBlock[] | null }
  | { sessionUpdate: "plan"; entries: PlanEntry[] }
  | { sessionUpdate: "plan_update"; plan: { type: string; planId?: string; entries?: PlanEntry[] } }
  | { sessionUpdate: "plan_removed" }
  | { sessionUpdate: "available_commands_update"; availableCommands: AvailableCommand[] }
  | { sessionUpdate: "current_mode_update"; currentModeId: string }
  | { sessionUpdate: "config_option_update"; configOptions: ConfigOption[] }
  | { sessionUpdate: "session_info_update"; title?: string | null; updatedAt?: string | null }
  | { sessionUpdate: "usage_update"; used: number; size: number; cost?: unknown; _meta?: Record<string, unknown> }
  );

/** One window of the subscription's usage limits, as Claude Code reports it after a reply. */
export interface PlanLimit {
  window: "five_hour" | "seven_day";
  /** 0 to 100. */
  percent: number;
  /** Epoch milliseconds. */
  resetsAt: number;
}

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
  /** Sent while a turn ran: it waits for that turn's end, then opens the next. */
  queued?: true;
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
  /** The calls of the sub-agent this call started, in order; the call's output is the sub-agent's report. */
  children: ToolCallItem[];
  /** Failed only because the user stopped the turn while it ran: not an error to show. */
  stopped: boolean;
  /** Bumped by every update the call gets: the view redraws it on this alone. */
  revision: number;
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

/** One field of an agent's question form: a choice, several, or a typed answer. */
export interface QuestionField {
  key: string;
  title: string;
  description: string;
  kind: "single" | "multi" | "text" | "number" | "boolean";
  options: { value: string; title: string; description: string }[];
  required: boolean;
}

export type QuestionAnswer = { action: string; content?: Record<string, unknown> };

export interface QuestionItem {
  kind: "question";
  id: number;
  requestId: string | number;
  message: string;
  fields: QuestionField[];
  answer: QuestionAnswer | null;
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
  | QuestionItem
  | NoticeItem;

export interface ConversationState {
  items: ThreadItem[];
  title: string | null;
  modeId: string | null;
  configOptions: ConfigOption[];
  commands: AvailableCommand[];
  usage: { used: number; size: number } | null;
  planLimits: PlanLimit[];
  toolCalls: Map<string, ToolCallItem>;
  /** v2 command output by terminal id, and the call that shows it once one names it. */
  terminals: Map<string, { output: string; exitCode: number | null; call: ToolCallItem | null }>;
  /** Calls the agent reported done that still run in the background: shown running until they leave its list. */
  background: Set<ToolCallItem>;
  /** v2 sub-agents by session id, each drawn as a sub-agent call holding its session's calls. */
  sessions: Map<string, ToolCallItem>;
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
    planLimits: [],
    toolCalls: new Map(),
    terminals: new Map(),
    background: new Set(),
    sessions: new Map(),
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

/**
 * A v2 diff's files. A git patch gives each file's hunks, both sides of each joined in order, and exact line
 * counts; without one, only which files changed is known.
 */
function patchDiffs(diff: DiffV2): FileDiff[] {
  if (diff.patch?.format !== "git_patch") {
    return diff.changes.map((change) => ({ path: change.path, oldText: null, newText: "", added: 0, removed: 0 }));
  }
  const files: { diff: FileDiff; before: string[]; after: string[] }[] = [];
  let file: (typeof files)[number] | undefined;
  let inHunk = false;
  for (const line of diff.patch.text.split("\n")) {
    if (line.startsWith("diff --git ") || (!file && line.startsWith("@@"))) {
      const change = diff.changes[files.length] ?? diff.changes[0];
      file = { diff: { path: change?.path ?? "", oldText: null, newText: "", added: 0, removed: 0 }, before: [], after: [] };
      files.push(file);
      inHunk = false;
    }
    if (!file) continue;
    if (line.startsWith("@@")) inHunk = true;
    else if (!inHunk || line.startsWith("\\")) continue;
    else if (line.startsWith("+")) {
      file.after.push(line.slice(1));
      file.diff.added++;
    } else if (line.startsWith("-")) {
      file.before.push(line.slice(1));
      file.diff.removed++;
    } else if (line.startsWith(" ")) {
      file.before.push(line.slice(1));
      file.after.push(line.slice(1));
    }
  }
  return files.map(({ diff: entry, before, after }, index) => {
    const created = (diff.changes[index] ?? diff.changes[0])?.operation === "add";
    entry.oldText = created ? null : before.map((line) => `${line}\n`).join("");
    entry.newText = after.map((line) => `${line}\n`).join("");
    return entry;
  });
}

function setContent(state: ConversationState, call: ToolCallItem, content: ToolCallContent[]): void {
  call.diffs = [];
  call.output = "";
  call.images = [];
  for (const entry of content) addContent(state, call, entry);
}

function addContent(state: ConversationState, call: ToolCallItem, entry: ToolCallContent): void {
  if (entry.type === "diff" && "changes" in entry) {
    call.diffs.push(...patchDiffs(entry));
  } else if (entry.type === "diff") {
    call.diffs.push({ path: entry.path, oldText: entry.oldText, newText: entry.newText, ...diffStats(entry.oldText, entry.newText) });
  } else if (entry.type === "terminal") {
    const terminal = terminalOf(state, entry.terminalId);
    terminal.call = call;
    call.output = terminal.output;
    if (terminal.exitCode !== null) call.exitCode = terminal.exitCode;
  } else if (entry.type === "content" && entry.content.type === "text") {
    call.output = call.output ? `${call.output}\n${entry.content.text}` : entry.content.text;
  } else if (entry.type === "content" && entry.content.type === "image") {
    call.images.push({ src: `data:${entry.content.mimeType};base64,${entry.content.data}`, alt: call.title });
  }
}

/** The call that started the sub-agent this update comes from: claude-agent-acp tags its sub-agents' updates so. */
function parentOf(update: { _meta?: Record<string, unknown> | null }): string | null {
  const parent = (update._meta?.claudeCode as { parentToolUseId?: unknown } | undefined)?.parentToolUseId;
  return typeof parent === "string" ? parent : null;
}

function newCall(state: ConversationState, toolCallId: string, receivedAt: number | null): ToolCallItem {
  const call: ToolCallItem = {
    kind: "toolCall",
    id: state.nextId++,
    toolCallId,
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
    children: [],
    stopped: false,
    revision: 0,
  };
  state.toolCalls.set(toolCallId, call);
  return call;
}

/** The call standing for a v2 sub-agent's session, made the first time anything names it. */
function sessionCall(state: ConversationState, sessionId: string, receivedAt: number | null, parentSession?: string): ToolCallItem {
  let call = state.sessions.get(sessionId);
  if (!call) {
    call = newCall(state, `session:${sessionId}`, receivedAt);
    call.toolKind = "think";
    call.status = "in_progress";
    call.rawInput = { subagent_type: "", description: "" };
    state.sessions.set(sessionId, call);
    const parent = parentSession === undefined ? undefined : sessionCall(state, parentSession, receivedAt);
    (parent ? parent.children : state.items).push(call);
  }
  return call;
}

function terminalOf(state: ConversationState, terminalId: string) {
  let terminal = state.terminals.get(terminalId);
  if (!terminal) {
    terminal = { output: "", exitCode: null, call: null };
    state.terminals.set(terminalId, terminal);
  }
  return terminal;
}

/** v2 command output, base64 text that replaces or extends the terminal's; an exit ends a call left running in the background. */
function applyTerminal(
  state: ConversationState,
  terminalId: string,
  data: string | null,
  replace: boolean,
  exit: { exitCode?: number | null } | null,
  receivedAt: number | null,
): void {
  const terminal = terminalOf(state, terminalId);
  if (data !== null) {
    const text = new TextDecoder().decode(Uint8Array.from(atob(data), (char) => char.charCodeAt(0)));
    terminal.output = replace ? text : terminal.output + text;
  }
  if (exit?.exitCode != null) terminal.exitCode = exit.exitCode;
  const call = terminal.call;
  if (!call) return;
  call.output = terminal.output;
  if (terminal.exitCode !== null) call.exitCode = terminal.exitCode;
  if (exit && state.background.delete(call)) settle(call, "completed", receivedAt);
  call.revision++;
}

function settle(call: ToolCallItem, status: ToolCallStatus, receivedAt: number | null): void {
  call.status = status;
  if (status === "completed" || status === "failed") call.endedAt ??= receivedAt;
  else call.endedAt = null;
}

/** A v2 session's work state, as the status of the call that stands for it. */
function sessionStatus(state: { state: string; stopReason?: string | null }): ToolCallStatus {
  if (state.state !== "idle") return "in_progress";
  return state.stopReason === "error" || state.stopReason === "cancelled" ? "failed" : "completed";
}

/** Marks the calls a v2 state lists as still running, and settles those no longer listed. */
function applyBackground(state: ConversationState, background: BackgroundWork[], receivedAt: number | null): void {
  const listed = new Set<ToolCallItem>();
  for (const work of background) {
    const call =
      "toolCallId" in work ? state.toolCalls.get(work.toolCallId) : "terminalId" in work ? state.terminals.get(work.terminalId)?.call : undefined;
    if (call) listed.add(call);
  }
  for (const call of state.background) {
    if (listed.has(call)) continue;
    settle(call, "completed", receivedAt);
    call.revision++;
  }
  for (const call of listed) {
    if (state.background.has(call) || call.status === "failed") continue;
    settle(call, "in_progress", receivedAt);
    call.revision++;
  }
  state.background = listed;
}

function applyToolCall(state: ConversationState, update: ToolCallFields & { childSession?: string }, receivedAt: number | null): void {
  let call = state.toolCalls.get(update.toolCallId);
  if (!call) {
    call = newCall(state, update.toolCallId, receivedAt);
    // Plumbing, not work: tracked so their updates land, never shown. Claude Code loading its deferred tools, and
    // Lilo's empty new tab and tab listing, whose page the next step names.
    if (update.name === "ToolSearch" || (update._meta?.claudeCode as { toolName?: unknown } | undefined)?.toolName === "ToolSearch") return;
    if (/tabs_(create|context)_mcp$/.test(update.title ?? "")) return;
    const parentId = parentOf(update);
    const parent =
      parentId !== null ? state.toolCalls.get(parentId) : update.childSession !== undefined ? sessionCall(state, update.childSession, receivedAt) : undefined;
    if (parent) parent.children.push(call);
    else state.items.push(call);
  }
  if (update.title != null) call.title = update.title;
  if (update.kind != null) call.toolKind = update.kind;
  // A call that runs on in the background stays running until the agent's list drops it.
  if (update.status != null && !state.background.has(call)) {
    call.status = update.status === "cancelled" ? "failed" : update.status === "paused" ? "in_progress" : update.status;
  }
  if (update.content != null) setContent(state, call, update.content);
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
  call.revision++;
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
  // A prompt queued mid-reply does not split the reply: its chunks keep joining the text before it.
  let at = state.items.length - 1;
  while (at >= 0 && state.items[at].kind === "user" && (state.items[at] as UserMessageItem).queued) at--;
  const last = state.items[at];
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

/** A v2 whole message: it replaces what its chunks or an earlier copy drew. */
function applyMessage(state: ConversationState, kind: "user" | "agent" | "thought", messageId: string, content: ContentBlock[]): void {
  const text = content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
  let item: ThreadItem | undefined;
  for (let i = state.items.length - 1; i >= 0 && !item; i--) {
    const candidate = state.items[i];
    if (candidate.kind === kind && candidate.messageId === messageId) item = candidate;
    // The prompt Lilo drew as it was sent: its echo names it.
    else if (kind === "user" && candidate.kind === "user" && candidate.messageId === null && candidate.text === text) {
      candidate.messageId = messageId;
      return;
    }
  }
  if (item && (item.kind === "agent" || item.kind === "thought" || item.kind === "user")) {
    item.text = text;
    if (item.kind === "user") item.context = [];
    for (const block of content) if (block.type !== "text") applyChunk(state, kind, block, messageId);
    return;
  }
  for (const block of content) applyChunk(state, kind, block, messageId);
}

const ITEM_UPDATES = new Set([
  "user_message_chunk",
  "agent_message_chunk",
  "agent_thought_chunk",
  "user_message",
  "agent_message",
  "agent_thought",
  "tool_call",
  "tool_call_update",
  "tool_call_content_chunk",
  "subagent_update",
  "plan",
  "plan_update",
]);

/** What a v2 sub-agent's own session sends that the thread draws: its calls and their output, and its state. */
const CHILD_UPDATES = new Set([
  "tool_call_update",
  "tool_call_content_chunk",
  "terminal_update",
  "terminal_output_chunk",
  "state_update",
  "subagent_update",
  "session_message",
]);

/**
 * Applies one `session/update` payload in place; unknown kinds are ignored. `receivedAt` is set for an
 * update that arrives live, null for one replayed from the log.
 */
export function applyUpdate(state: ConversationState, update: SessionUpdate, receivedAt: number | null = null): ConversationState {
  // A sub-agent's words, plan and usage are not the conversation's.
  if (update.childSession !== undefined && !CHILD_UPDATES.has(update.sessionUpdate)) return state;
  // v2 echoes the prompt whole: the one drawn as it was sent takes its id.
  if (update.sessionUpdate === "user_message" && state.pendingEcho !== null) {
    state.pendingEcho = null;
    const sent = state.items.findLast((item) => item.kind === "user");
    if (sent?.kind === "user" && sent.messageId === null) sent.messageId = update.messageId;
    return state;
  }
  if (update.sessionUpdate !== "user_message_chunk" && update.sessionUpdate !== "state_update") state.pendingEcho = null;
  // Only updates that draw something start a turn, or a v2 agent starting one: usage or command lists also arrive between turns.
  const starts = ITEM_UPDATES.has(update.sessionUpdate) || (update.sessionUpdate === "state_update" && update.state !== "idle" && update.childSession === undefined);
  if (receivedAt !== null && state.turnStartedAt === null && starts) {
    state.turnStartedAt = receivedAt;
  }
  switch (update.sessionUpdate) {
    case "user_message_chunk":
      applyChunk(state, "user", update.content, update.messageId ?? null);
      break;
    // A sub-agent's own words are not the reply: what it hands back arrives as its call's output.
    case "agent_message_chunk":
      if (parentOf(update) === null) applyChunk(state, "agent", update.content, update.messageId ?? null);
      break;
    case "agent_thought_chunk":
      if (parentOf(update) === null) applyChunk(state, "thought", update.content, update.messageId ?? null);
      break;
    case "user_message":
      applyMessage(state, "user", update.messageId, update.content ?? []);
      break;
    case "agent_message":
      applyMessage(state, "agent", update.messageId, update.content ?? []);
      break;
    case "agent_thought":
      applyMessage(state, "thought", update.messageId, update.content ?? []);
      break;
    case "tool_call":
    case "tool_call_update":
      applyToolCall(state, update, receivedAt);
      break;
    case "tool_call_content_chunk": {
      const call = state.toolCalls.get(update.toolCallId);
      if (!call) break;
      addContent(state, call, update.content);
      call.revision++;
      break;
    }
    case "terminal_update":
      applyTerminal(state, update.terminalId, update.output?.data ?? null, true, update.exitStatus ?? null, receivedAt);
      break;
    case "terminal_output_chunk":
      applyTerminal(state, update.terminalId, update.data, false, null, receivedAt);
      break;
    case "state_update":
      if (update.childSession !== undefined) {
        const call = sessionCall(state, update.childSession, receivedAt);
        settle(call, sessionStatus(update), receivedAt);
        call.revision++;
      } else if (update.background !== undefined) {
        applyBackground(state, update.background ?? [], receivedAt);
      }
      break;
    case "subagent_update": {
      const call = sessionCall(state, update.sessionId, receivedAt, update.childSession);
      // claude-agent-acp titles a sub-agent with its task, and describes it with its kind.
      if (update.title) call.title = update.title;
      const input = call.rawInput as { subagent_type: string; description: string };
      if (update.description) input.subagent_type = update.description;
      if (update.title) input.description = update.title;
      if (update.state) settle(call, sessionStatus(update.state), receivedAt);
      call.revision++;
      break;
    }
    case "session_message": {
      // A sub-agent's report reaches the session that started it: the output of the call standing for it.
      const call = update.senderSessionId ? state.sessions.get(update.senderSessionId) : undefined;
      const receiver = update.childSession === undefined ? state.items : state.sessions.get(update.childSession)?.children;
      if (!call || !receiver?.includes(call) || "recipientMessageId" in update) break;
      call.output = (update.content ?? []).flatMap((block) => (block.type === "text" ? [block.text] : [])).join("\n");
      call.revision++;
      break;
    }
    case "plan":
    case "plan_update": {
      const entries = update.sessionUpdate === "plan" ? update.entries : update.plan.type === "items" ? update.plan.entries : undefined;
      if (!entries) break;
      if (state.plan) state.plan.entries = entries;
      else {
        state.plan = { kind: "plan", id: state.nextId++, entries };
        state.items.push(state.plan);
      }
      break;
    }
    case "plan_removed":
      if (state.plan) state.items = state.items.filter((item) => item !== state.plan);
      state.plan = null;
      break;
    case "available_commands_update":
      state.commands = update.availableCommands;
      break;
    case "current_mode_update":
      state.modeId = update.currentModeId;
      break;
    case "config_option_update":
      state.configOptions = configOptions(update.configOptions);
      break;
    case "session_info_update":
      // Claude re-titles a session after a command such as /compact with the command itself.
      if (update.title !== undefined && !update.title?.startsWith("/")) state.title = update.title;
      break;
    case "usage_update": {
      state.usage = { used: update.used, size: update.size };
      // claude-agent-acp relays Claude Code's rate limit event here; most usage updates carry none.
      const windows = (update._meta?.["_claude/rateLimit"] as { unifiedWindows?: Record<string, { utilization?: unknown; resetsAt?: unknown }> } | undefined)
        ?.unifiedWindows;
      if (windows) {
        state.planLimits = (["five_hour", "seven_day"] as const).flatMap((window) => {
          const { utilization, resetsAt } = windows[window] ?? {};
          return typeof utilization === "number" && typeof resetsAt === "number"
            ? [{ window, percent: Math.min(100, Math.round(utilization * 100)), resetsAt: resetsAt * 1000 }]
            : [];
        });
      }
      break;
    }
  }
  return state;
}

/** Options as the thread reads them: v2's `configId` as `id`, and grouped values in one list. */
export function configOptions(options: unknown[]): ConfigOption[] {
  return options.map((raw) => {
    type Value = ConfigOption["options"][number];
    const option = raw as Omit<ConfigOption, "options"> & { configId?: string; options?: (Value | { options: Value[] })[] };
    return {
      ...option,
      id: option.configId ?? option.id,
      options: Array.isArray(option.options) ? option.options.flatMap((entry) => ("options" in entry ? entry.options : [entry])) : [],
    };
  });
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
  state.items.push({ kind: "user", id: state.nextId++, messageId: null, text, context, ...(state.turnStartedAt !== null && { queued: true as const }) });
  state.pendingEcho = text;
  if (receivedAt !== null) state.turnStartedAt ??= receivedAt;
  return state;
}

/** Closes the running turn with its footer; a second end in a row adds nothing. */
export function endTurn(state: ConversationState, stopReason: string, receivedAt: number | null = null): ConversationState {
  const started = state.turnStartedAt;
  state.turnStartedAt = null;
  if (state.items[state.items.length - 1]?.kind === "turnEnd") return state;
  // Prompts sent while the turn ran wait after its footer; the first of them opens the next turn.
  const waiting: UserMessageItem[] = [];
  for (let i = state.items.length - 1; i >= 0 && state.items[i].kind !== "turnEnd"; i--) {
    const item = state.items[i];
    if (item.kind === "user" && item.queued) {
      state.items.splice(i, 1);
      waiting.unshift(item);
    }
  }
  // The call a stop cuts off is the turn's last, failing as the turn ends; an earlier failure stays one.
  const last = state.items.findLast((item) => item.kind === "toolCall" || item.kind === "user");
  if (
    stopReason === "cancelled" && last?.kind === "toolCall" && last.status === "failed" &&
    (last.endedAt === null || receivedAt === null || receivedAt - last.endedAt < 3000)
  ) {
    last.stopped = true;
    last.revision++;
  }
  state.items.push({
    kind: "turnEnd",
    id: state.nextId++,
    stopReason,
    durationMs: started !== null && receivedAt !== null ? receivedAt - started : null,
  }, ...waiting);
  if (waiting.length) {
    delete waiting[0].queued;
    state.turnStartedAt = receivedAt;
  }
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

/** Reads an `elicitation/create` schema: ACP forms are flat, one property per field. */
export function questionFields(schema: unknown): QuestionField[] {
  const record = (value: unknown): Record<string, unknown> => (value !== null && typeof value === "object" ? (value as Record<string, unknown>) : {});
  const text = (value: unknown): string => (typeof value === "string" ? value : "");
  const root = record(schema);
  const required = Array.isArray(root.required) ? root.required : [];
  // Titled options (oneOf/anyOf of {const, title}) or a bare enum, as the MCP form schema allows.
  const choices = (property: Record<string, unknown>) => {
    const titled = Array.isArray(property.oneOf) ? property.oneOf : Array.isArray(property.anyOf) ? property.anyOf : null;
    if (titled) return titled.map(record).map((option) => ({ value: String(option.const ?? ""), title: text(option.title) || String(option.const ?? ""), description: text(option.description) }));
    const names = Array.isArray(property.enumNames) ? property.enumNames : [];
    return Array.isArray(property.enum) ? property.enum.map((value, index) => ({ value: String(value), title: text(names[index]) || String(value), description: "" })) : [];
  };
  // The form reaches the chrome through a Swift dictionary, which keeps no key order: keys in natural
  // order put question_1 after question_0, and each one's companion field right after it.
  const properties = Object.entries(record(root.properties)).sort(([a], [b]) => a.localeCompare(b, "en", { numeric: true }));
  return properties.map(([key, value]) => {
    const property = record(value);
    const options = property.type === "array" ? choices(record(property.items)) : choices(property);
    const kind = property.type === "array" ? "multi" : options.length ? "single" : property.type === "boolean" ? "boolean" : property.type === "number" || property.type === "integer" ? "number" : "text";
    return { key, title: text(property.title), description: text(property.description), kind, options, required: required.includes(key) };
  });
}

export function addQuestion(state: ConversationState, requestId: string | number, message: string, schema: unknown, toolCallId?: string): ConversationState {
  // The call that asks says no more than its question: the question stands for it in the thread.
  const call = toolCallId ? state.toolCalls.get(toolCallId) : undefined;
  if (call) state.items = state.items.filter((item) => item !== call);
  state.items.push({ kind: "question", id: state.nextId++, requestId, message, fields: questionFields(schema), answer: null });
  return state;
}

export function resolveQuestion(state: ConversationState, requestId: string | number, answer: QuestionAnswer): ConversationState {
  for (let i = state.items.length - 1; i >= 0; i--) {
    const item = state.items[i];
    if (item.kind === "question" && item.requestId === requestId) {
      item.answer = answer;
      break;
    }
  }
  return state;
}

export function addNotice(state: ConversationState, text: string): ConversationState {
  state.items.push({ kind: "notice", id: state.nextId++, text });
  return state;
}
