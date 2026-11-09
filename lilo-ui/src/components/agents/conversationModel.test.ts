import assert from "node:assert/strict";
import test from "node:test";

import {
  addNotice,
  addPermissionRequest,
  addQuestion,
  addUserPrompt,
  applyUpdate,
  applyUpdates,
  diffStats,
  emptyConversation,
  endTurn,
  questionFields,
  resolvePermission,
  resolveQuestion,
  type SessionUpdate,
  type ToolCallItem,
} from "./conversationModel";

function agentText(text: string, messageId?: string): SessionUpdate {
  return { sessionUpdate: "agent_message_chunk", content: { type: "text", text }, messageId };
}

function completedCall(toolCallId: string, kind: "read" | "search" | "edit"): SessionUpdate {
  return { sessionUpdate: "tool_call", toolCallId, title: `${kind} ${toolCallId}`, kind, status: "completed" };
}

test("consecutive chunks of the same kind concatenate", () => {
  const state = applyUpdates(emptyConversation(), [agentText("Hel"), agentText("lo")]);
  assert.equal(state.items.length, 1);
  assert.deepEqual([state.items[0].kind, (state.items[0] as { text: string }).text], ["agent", "Hello"]);
});

test("a new messageId starts a new message", () => {
  const state = applyUpdates(emptyConversation(), [agentText("a", "m1"), agentText("b", "m1"), agentText("c", "m2")]);
  assert.deepEqual(
    state.items.map((item) => (item as { text: string }).text),
    ["ab", "c"],
  );
});

test("thoughts and messages are separate items", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "think" } },
    agentText("say"),
    { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "again" } },
  ]);
  assert.deepEqual(
    state.items.map((item) => item.kind),
    ["thought", "agent", "thought"],
  );
});

test("user chunks carry resources as context chips", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Look at this" } },
    {
      sessionUpdate: "user_message_chunk",
      content: { type: "resource_link", uri: "https://example.com/a", name: "a", title: "Page A" },
    },
    { sessionUpdate: "user_message_chunk", content: { type: "resource", resource: { uri: "file:///p/b.ts", text: "x" } } },
  ]);
  assert.equal(state.items.length, 1);
  const user = state.items[0];
  assert.equal(user.kind, "user");
  assert.deepEqual(user.kind === "user" && user.context, [
    { label: "Page A", uri: "https://example.com/a" },
    { label: "file:///p/b.ts", uri: "file:///p/b.ts" },
  ]);
});

test("tool_call_update merges into the call and replaces its content", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call", toolCallId: "t1", title: "Run tests", kind: "execute", status: "pending" },
    {
      sessionUpdate: "tool_call_update",
      toolCallId: "t1",
      status: "completed",
      content: [
        { type: "content", content: { type: "text", text: "ok 1" } },
        { type: "content", content: { type: "text", text: "ok 2" } },
      ],
      locations: [{ path: "/p/a.ts", line: 3 }],
    },
  ]);
  assert.equal(state.items.length, 1);
  const call = state.items[0] as ToolCallItem;
  assert.equal(call.title, "Run tests");
  assert.equal(call.toolKind, "execute");
  assert.equal(call.status, "completed");
  assert.equal(call.output, "ok 1\nok 2");
  assert.deepEqual(call.locations, [{ path: "/p/a.ts", line: 3 }]);
});

test("tool calls stay in place as they complete, in any order", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call", toolCallId: "r1", title: "a", kind: "read", status: "in_progress" },
    { sessionUpdate: "tool_call", toolCallId: "r2", title: "b", kind: "read", status: "in_progress" },
    completedCall("e1", "edit"),
    { sessionUpdate: "tool_call_update", toolCallId: "r2", status: "completed" },
    { sessionUpdate: "tool_call_update", toolCallId: "r1", status: "failed" },
  ]);
  const before = [...state.items];
  applyUpdate(state, { sessionUpdate: "tool_call_update", toolCallId: "r1", status: "completed", title: "renamed" });
  assert.deepEqual(state.items, before);
  assert.deepEqual(
    state.items.map((item) => item.kind === "toolCall" && `${item.toolCallId}:${item.status}`),
    ["r1:completed", "r2:completed", "e1:completed"],
  );
  assert.equal((state.items[0] as ToolCallItem).title, "renamed");
});

test("a slash command never becomes the conversation's title", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "session_info_update", title: "Fix the footer" },
    { sessionUpdate: "session_info_update", title: "/compact" },
  ]);
  assert.equal(state.title, "Fix the footer");
});

test("Claude Code loading its deferred tools stays out of the thread", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call", toolCallId: "ts", title: "ToolSearch", kind: "other", status: "pending", _meta: { claudeCode: { toolName: "ToolSearch" } } },
    { sessionUpdate: "tool_call_update", toolCallId: "ts", status: "completed" },
    { sessionUpdate: "tool_call", toolCallId: "r1", title: "Read a", kind: "read", status: "completed" },
  ]);
  assert.deepEqual(state.items.map((item) => item.kind === "toolCall" && item.toolCallId), ["r1"]);
});

test("Lilo's empty new tab and tab listing stay out of the thread, the page opened next shows", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call", toolCallId: "ctx", title: "mcp__lilo__tabs_context_mcp", kind: "other", status: "completed" },
    { sessionUpdate: "tool_call", toolCallId: "new", title: "mcp__lilo__tabs_create_mcp", kind: "other", status: "pending" },
    { sessionUpdate: "tool_call_update", toolCallId: "new", status: "completed" },
    { sessionUpdate: "tool_call", toolCallId: "nav", title: "mcp__lilo__navigate", kind: "other", status: "completed" },
  ]);
  assert.deepEqual(state.items.map((item) => item.kind === "toolCall" && item.toolCallId), ["nav"]);
});

test("a sub-agent's calls nest under the call that started it, and its own words stay out of the reply", () => {
  const child = { _meta: { claudeCode: { parentToolUseId: "task" } } };
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call", toolCallId: "task", title: "Explore", kind: "think", status: "in_progress" },
    { sessionUpdate: "tool_call", toolCallId: "c1", title: "read a", kind: "read", status: "in_progress", ...child },
    { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "thinking aloud" }, ...child },
    { sessionUpdate: "tool_call", toolCallId: "c2", title: "orphan", kind: "read", status: "completed", _meta: { claudeCode: { parentToolUseId: "gone" } } },
    { sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed", ...child },
    agentText("Done"),
  ]);
  assert.deepEqual(
    state.items.map((item) => (item.kind === "toolCall" ? item.toolCallId : item.kind)),
    ["task", "c2", "agent"],
  );
  const task = state.items[0] as ToolCallItem;
  assert.deepEqual(
    task.children.map((call) => `${call.toolCallId}:${call.status}`),
    ["c1:completed"],
  );
  assert.equal((state.items[2] as { text: string }).text, "Done");
});

test("live updates time their calls and the turn; replayed ones do not", () => {
  const state = addUserPrompt(emptyConversation(), "go", [], 1000);
  applyUpdate(state, { sessionUpdate: "tool_call", toolCallId: "x1", title: "npm test", kind: "execute", status: "in_progress", rawInput: { command: "npm test" } }, 2000);
  applyUpdate(state, { sessionUpdate: "tool_call_update", toolCallId: "x1", status: "failed", rawOutput: { exit_code: 1 } }, 3500);
  applyUpdate(state, agentText("done"), 4000);
  endTurn(state, "end_turn", 5000);
  endTurn(state, "end_turn", 6000);
  const call = state.items[1] as ToolCallItem;
  assert.deepEqual([call.startedAt, call.endedAt, call.exitCode, call.rawInput], [2000, 3500, 1, { command: "npm test" }]);
  assert.deepEqual(state.items.at(-1), { kind: "turnEnd", id: 4, stopReason: "end_turn", durationMs: 4000 });
  assert.equal(state.items.filter((item) => item.kind === "turnEnd").length, 1);
  assert.equal(state.turnStartedAt, null);

  const replayed = applyUpdates(emptyConversation(), [completedCall("r1", "read"), agentText("ok")]);
  endTurn(replayed, "cancelled");
  assert.deepEqual([(replayed.items[0] as ToolCallItem).startedAt, replayed.items.at(-1)], [
    null,
    { kind: "turnEnd", id: 3, stopReason: "cancelled", durationMs: null },
  ]);
});

test("a stop marks the call it cut off as stopped, never an earlier failure", () => {
  const run = (calls: [string, number][], stopReason: string, at: number) => {
    const state = addUserPrompt(emptyConversation(), "go", [], 1000);
    for (const [id, end] of calls) {
      applyUpdate(state, { sessionUpdate: "tool_call", toolCallId: id, title: id, kind: "execute", status: "in_progress" }, end - 500);
      applyUpdate(state, { sessionUpdate: "tool_call_update", toolCallId: id, status: "failed" }, end);
    }
    endTurn(state, stopReason, at);
    return state.items.filter((item): item is ToolCallItem => item.kind === "toolCall").map((call) => call.stopped);
  };
  assert.deepEqual(run([["a", 2000], ["b", 5000]], "cancelled", 5200), [false, true]);
  assert.deepEqual(run([["a", 2000]], "cancelled", 9000), [false]);
  assert.deepEqual(run([["a", 2000]], "end_turn", 2100), [false]);
});

test("prompts queued while a turn ran wait after its footer, and the first opens the next turn", () => {
  const state = addUserPrompt(emptyConversation(), "first", [], 1000);
  addUserPrompt(state, "second", [], 1200);
  addUserPrompt(state, "third", [], 1300);
  applyUpdate(state, agentText("working"), 2000);
  endTurn(state, "end_turn", 3000);
  const shape = () => state.items.map((item) => (item.kind === "user" ? `${item.text}${item.queued ? "?" : ""}` : item.kind));
  assert.deepEqual(shape(), ["first", "agent", "turnEnd", "second", "third?"]);
  applyUpdate(state, agentText("again"), 3500);
  endTurn(state, "end_turn", 4000);
  assert.deepEqual(shape(), ["first", "agent", "turnEnd", "second", "agent", "turnEnd", "third"]);

  const midReply = addUserPrompt(emptyConversation(), "go", [], 1000);
  applyUpdate(midReply, agentText("Hel"), 1100);
  addUserPrompt(midReply, "next", [], 1150);
  applyUpdate(midReply, agentText("lo"), 1200);
  assert.deepEqual(midReply.items.flatMap((item) => (item.kind === "agent" ? [item.text] : [])), ["Hello"]);

  const silent = addUserPrompt(emptyConversation(), "first", [], 1000);
  addUserPrompt(silent, "queued", [], 1500);
  endTurn(silent, "error", 2000);
  assert.deepEqual(silent.items.map((item) => item.kind), ["user", "turnEnd", "user"]);
});

test("a turn starts with its first item, not with usage or command updates", () => {
  const state = emptyConversation();
  applyUpdate(state, { sessionUpdate: "usage_update", used: 1, size: 10 }, 100);
  assert.equal(state.turnStartedAt, null);
  applyUpdate(state, agentText("hi"), 200);
  applyUpdate(state, agentText("!"), 300);
  assert.equal(state.turnStartedAt, 200);
});

test("diffStats counts added and removed lines, including a new file", () => {
  assert.deepEqual(diffStats(null, "a\nb\nc\n"), { added: 3, removed: 0 });
  assert.deepEqual(diffStats("a\nb\nc\n", "a\nB\nc\nd\n"), { added: 2, removed: 1 });
  assert.deepEqual(diffStats("x\nx\n", "x\n"), { added: 0, removed: 1 });
  assert.deepEqual(diffStats("a", ""), { added: 0, removed: 1 });

  const state = applyUpdate(emptyConversation(), {
    sessionUpdate: "tool_call",
    toolCallId: "e1",
    title: "Write",
    kind: "edit",
    content: [{ type: "diff", path: "/p/new.ts", oldText: null, newText: "one\ntwo" }],
  });
  assert.deepEqual((state.items[0] as ToolCallItem).diffs, [
    { path: "/p/new.ts", oldText: null, newText: "one\ntwo", added: 2, removed: 0 },
  ]);
});

test("a plan update replaces the plan where it first appeared", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "plan", entries: [{ content: "step", priority: "high", status: "pending" }] },
    agentText("working"),
    { sessionUpdate: "plan", entries: [{ content: "step", priority: "high", status: "completed" }] },
  ]);
  assert.deepEqual(
    state.items.map((item) => item.kind),
    ["plan", "agent"],
  );
  assert.equal(state.items[0].kind === "plan" && state.items[0].entries[0].status, "completed");
});

test("a permission request is added then resolved with the chosen option", () => {
  const state = addPermissionRequest(emptyConversation(), {
    requestId: 7,
    toolCall: { toolCallId: "t1", title: "rm -rf build" },
    options: [
      { optionId: "yes", name: "Allow", kind: "allow_once" },
      { optionId: "no", name: "Reject", kind: "reject_once" },
    ],
  });
  assert.equal(state.items[0].kind === "permission" && state.items[0].answer, null);
  resolvePermission(state, 7, "no");
  assert.equal(state.items[0].kind === "permission" && state.items[0].answer, "no");
});

test("the agent's echo of a local prompt is not duplicated", () => {
  const state = addUserPrompt(emptyConversation(), "Fix the bug", [{ label: "Page", uri: "https://example.com" }]);
  applyUpdates(state, [
    { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Fix the " } },
    { sessionUpdate: "user_message_chunk", content: { type: "text", text: "bug" } },
    { sessionUpdate: "user_message_chunk", content: { type: "resource_link", uri: "https://example.com", name: "Page" } },
    agentText("On it"),
    { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Fix the bug" } },
  ]);
  assert.deepEqual(
    state.items.map((item) => [item.kind, (item as { text: string }).text]),
    [
      ["user", "Fix the bug"],
      ["agent", "On it"],
      ["user", "Fix the bug"],
    ],
  );
  assert.equal(state.items[0].kind === "user" && state.items[0].context.length, 1);
});

test("a different user chunk after a local prompt is shown", () => {
  const state = addUserPrompt(emptyConversation(), "hello", []);
  applyUpdate(state, { sessionUpdate: "user_message_chunk", content: { type: "text", text: "other" }, messageId: "u2" });
  assert.equal(state.items.length, 2);
});

test("unknown updates are ignored", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "compaction_update", status: "started" } as unknown as SessionUpdate,
    { sessionUpdate: "notice", text: "x" } as unknown as SessionUpdate,
  ]);
  assert.equal(state.items.length, 0);
});

test("session metadata updates set title, mode, usage, commands and config", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "session_info_update", title: "Bug hunt" },
    { sessionUpdate: "session_info_update", updatedAt: "2026-10-29T10:00:00Z" },
    { sessionUpdate: "current_mode_update", currentModeId: "plan" },
    { sessionUpdate: "usage_update", used: 1200, size: 200000, cost: { amount: 0.1, currency: "USD" } },
    { sessionUpdate: "available_commands_update", availableCommands: [{ name: "review", description: "Review" }] },
    {
      sessionUpdate: "config_option_update",
      configOptions: [{ id: "model", name: "Model", currentValue: "m1", options: [{ value: "m1", name: "M1" }] }],
    },
  ]);
  assert.equal(state.title, "Bug hunt");
  assert.equal(state.modeId, "plan");
  assert.deepEqual(state.usage, { used: 1200, size: 200000 });
  assert.equal(state.commands[0].name, "review");
  assert.equal(state.configOptions[0].currentValue, "m1");
  assert.equal(state.items.length, 0);
});

test("a usage update carrying a rate limit event sets the plan limits, later plain ones keep them", () => {
  const state = applyUpdates(emptyConversation(), [
    {
      sessionUpdate: "usage_update",
      used: 1,
      size: 10,
      _meta: {
        "_claude/rateLimit": {
          status: "allowed",
          unifiedWindows: {
            seven_day: { utilization: 0.564, resetsAt: 1_800_000_000, status: "allowed" },
            five_hour: { utilization: 1.2, resetsAt: 1_799_990_000, status: "rejected" },
            overage: { utilization: 0.1, resetsAt: 1_800_000_000 },
          },
        },
      },
    },
    { sessionUpdate: "usage_update", used: 2, size: 10 },
  ]);
  assert.deepEqual(state.planLimits, [
    { window: "five_hour", percent: 100, resetsAt: 1_799_990_000_000 },
    { window: "seven_day", percent: 56, resetsAt: 1_800_000_000_000 },
  ]);
  applyUpdate(state, { sessionUpdate: "usage_update", used: 3, size: 10, _meta: { "_claude/rateLimit": { unifiedWindows: {} } } });
  assert.deepEqual(state.planLimits, []);
});

test("notices are appended", () => {
  const state = addNotice(emptyConversation(), "Files restored");
  assert.deepEqual(state.items, [{ kind: "notice", id: 1, text: "Files restored" }]);
});

test("agent images become thread items; local image links do too, other links do not", () => {
  const state = applyUpdates(emptyConversation(), [
    agentText("Here:", "m1"),
    { sessionUpdate: "agent_message_chunk", content: { type: "image", data: "AAAA", mimeType: "image/png" }, messageId: "m1" },
    { sessionUpdate: "agent_message_chunk", content: { type: "resource_link", uri: "file:///p/shot.png", name: "shot.png" }, messageId: "m1" },
    { sessionUpdate: "agent_message_chunk", content: { type: "resource_link", uri: "file:///p/notes.md", name: "notes.md" }, messageId: "m1" },
    agentText("done", "m1"),
  ]);
  assert.deepEqual(
    state.items.map((item) => (item.kind === "image" ? `image:${item.src}:${item.alt}` : `${item.kind}:${(item as { text: string }).text}`)),
    ["agent:Here:", "image:data:image/png;base64,AAAA:", "image:file:///p/shot.png:shot.png", "agent:done"],
  );
});

test("tool call images are kept with the call and replaced with its content", () => {
  const state = applyUpdates(emptyConversation(), [
    {
      sessionUpdate: "tool_call",
      toolCallId: "s1",
      title: "Screenshot",
      kind: "other",
      status: "completed",
      content: [
        { type: "content", content: { type: "text", text: "captured" } },
        { type: "content", content: { type: "image", data: "BBBB", mimeType: "image/jpeg" } },
      ],
    },
  ]);
  const call = state.items[0] as ToolCallItem;
  assert.equal(call.output, "captured");
  assert.deepEqual(call.images, [{ src: "data:image/jpeg;base64,BBBB", alt: "Screenshot" }]);
  applyUpdate(state, { sessionUpdate: "tool_call_update", toolCallId: "s1", content: [] });
  assert.deepEqual(call.images, []);
});

test("an agent's question form reads as choices, several choices and typed answers", () => {
  const fields = questionFields({
    type: "object",
    required: ["approach"],
    properties: {
      approach: { type: "string", title: "Approach", oneOf: [{ const: "a", title: "Rewrite", description: "Start over" }, { const: "b", title: "Patch" }] },
      targets: { type: "array", items: { anyOf: [{ const: "web", title: "Web" }, { const: "mac", title: "Mac" }] } },
      size: { type: "string", enum: ["s", "m"] },
      note: { type: "string", title: "Other" },
      count: { type: "integer" },
      confirm: { type: "boolean", title: "Sure" },
    },
  });
  assert.deepEqual(
    fields.map((field) => [field.key, field.kind, field.options.map((option) => option.title), field.required]),
    [
      ["approach", "single", ["Rewrite", "Patch"], true],
      ["confirm", "boolean", [], false],
      ["count", "number", [], false],
      ["note", "text", [], false],
      ["size", "single", ["s", "m"], false],
      ["targets", "multi", ["Web", "Mac"], false],
    ],
  );
  assert.equal(fields[0].options[0].description, "Start over");
});

test("a question waits for its answer, then keeps it", () => {
  const state = addQuestion(emptyConversation(), "q1", "Which one?", { type: "object", properties: { pick: { type: "string", enum: ["x"] } } });
  const item = state.items[0];
  assert.equal(item.kind === "question" && item.answer, null);
  resolveQuestion(state, "q1", { action: "accept", content: { pick: "x" } });
  // The call that asked leaves the thread: the question stands for it.
  const asked = applyUpdates(emptyConversation(), [{ sessionUpdate: "tool_call", toolCallId: "t1", title: "Which one?", kind: "other", status: "pending" }]);
  addQuestion(asked, "q2", "Which one?", {}, "t1");
  assert.deepEqual(asked.items.map((entry) => entry.kind), ["question"]);
  assert.deepEqual(item.kind === "question" && item.answer, { action: "accept", content: { pick: "x" } });
});

test("question fields come in natural key order, each companion after its question", () => {
  const keys = questionFields({ properties: { question_1_custom: {}, question_10: {}, question_0: {}, question_1: {}, question_0_custom: {} } }).map((field) => field.key);
  assert.deepEqual(keys, ["question_0", "question_0_custom", "question_1", "question_1_custom", "question_10"]);
});

// ACP v2

const base64 = (text: string) => Buffer.from(text, "utf8").toString("base64");

test("v2: the first tool_call_update creates the call, omitted fields keep, cancelled reads as failed", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call_update", toolCallId: "t1", title: "Read a.ts", kind: "read", status: "in_progress" },
    { sessionUpdate: "tool_call_update", toolCallId: "t1", status: "cancelled" },
  ]);
  const call = state.items[0] as ToolCallItem;
  assert.deepEqual([state.items.length, call.title, call.toolKind, call.status], [1, "Read a.ts", "read", "failed"]);
});

test("v2: Claude Code loading its deferred tools stays out of the thread, named on its first update", () => {
  const state = applyUpdates(emptyConversation(), [{ sessionUpdate: "tool_call_update", toolCallId: "t1", name: "ToolSearch", title: "ToolSearch", status: "pending" }]);
  assert.equal(state.items.length, 0);
});

test("v2: a command's terminal output streams in base64 into its call, and its exit sets the code", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "terminal_update", terminalId: "x", output: null },
    { sessionUpdate: "tool_call_update", toolCallId: "t1", kind: "execute", status: "in_progress", content: [{ type: "terminal", terminalId: "x" }] },
    { sessionUpdate: "terminal_output_chunk", terminalId: "x", data: base64("héllo ") },
    { sessionUpdate: "terminal_output_chunk", terminalId: "x", data: base64("world") },
    { sessionUpdate: "terminal_update", terminalId: "x", exitStatus: { exitCode: 2 } },
  ]);
  const call = state.items[0] as ToolCallItem;
  assert.deepEqual([call.output, call.exitCode], ["héllo world", 2]);
  applyUpdate(state, { sessionUpdate: "terminal_update", terminalId: "x", output: { data: base64("replaced") } });
  assert.equal(call.output, "replaced");
});

test("v2: a call the agent reports done but lists in the background stays running until it leaves the list", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call_update", toolCallId: "bash", kind: "execute", status: "in_progress", content: [{ type: "terminal", terminalId: "bash" }] },
    { sessionUpdate: "tool_call_update", toolCallId: "bash", status: "completed" },
    { sessionUpdate: "state_update", state: "idle", stopReason: "end_turn", background: [{ type: "terminal", terminalId: "bash" }] },
  ], 1000);
  const call = state.items[0] as ToolCallItem;
  assert.deepEqual([call.status, call.endedAt], ["in_progress", null]);
  applyUpdate(state, { sessionUpdate: "tool_call_update", toolCallId: "bash", status: "completed" }, 1500);
  assert.equal(call.status, "in_progress");
  applyUpdate(state, { sessionUpdate: "state_update", state: "idle", background: [] }, 2000);
  assert.deepEqual([call.status, call.endedAt], ["completed", 2000]);
});

test("v2: a background terminal's exit settles its call", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call_update", toolCallId: "bash", kind: "execute", status: "completed", content: [{ type: "terminal", terminalId: "bash" }] },
    { sessionUpdate: "state_update", state: "running", background: [{ type: "terminal", terminalId: "bash" }] },
    { sessionUpdate: "terminal_update", terminalId: "bash", exitStatus: { exitCode: null } },
  ]);
  assert.equal((state.items[0] as ToolCallItem).status, "completed");
});

test("v2: a turn the agent starts itself is timed from its running state", () => {
  const state = emptyConversation();
  applyUpdate(state, { sessionUpdate: "state_update", state: "running" }, 1000);
  applyUpdate(state, agentText("Done."), 1200);
  endTurn(state, "end_turn", 4000);
  const end = state.items.at(-1);
  assert.deepEqual([end?.kind, end?.kind === "turnEnd" && end.durationMs], ["turnEnd", 3000]);
});

test("v2: whole messages replace what their chunks drew, and the prompt's echo is not drawn again", () => {
  const state = emptyConversation();
  addUserPrompt(state, "Fix it", [], 1);
  applyUpdates(state, [
    { sessionUpdate: "state_update", state: "running" },
    { sessionUpdate: "user_message", messageId: "u1", content: [{ type: "text", text: "Fix it" }] },
    { sessionUpdate: "agent_message_chunk", messageId: "a1", content: { type: "text", text: "Wor" } },
    { sessionUpdate: "agent_message", messageId: "a1", content: [{ type: "text", text: "Working on it." }] },
  ]);
  assert.deepEqual(
    state.items.map((item) => [item.kind, (item as { text: string }).text, (item as { messageId: string | null }).messageId]),
    [["user", "Fix it", "u1"], ["agent", "Working on it.", "a1"]],
  );
  applyUpdate(state, { sessionUpdate: "user_message", messageId: "u2", content: [{ type: "text", text: "Replayed" }] });
  assert.equal((state.items.at(-1) as { text: string }).text, "Replayed");
});

test("v2: a diff's git patch gives the card both sides of each hunk and exact line counts", () => {
  const patch = [
    "diff --git a/src/a.ts b/src/a.ts",
    "--- a/src/a.ts",
    "+++ b/src/a.ts",
    "@@ -1,3 +1,3 @@",
    " keep",
    "-old",
    "+new",
    "+more",
    " tail",
    "\\ No newline at end of file",
    "diff --git a/src/b.ts b/src/b.ts",
    "--- /dev/null",
    "+++ b/src/b.ts",
    "@@ -0,0 +1 @@",
    "+created",
  ].join("\n");
  const state = applyUpdates(emptyConversation(), [
    {
      sessionUpdate: "tool_call_update",
      toolCallId: "e1",
      kind: "edit",
      content: [{ type: "diff", changes: [{ operation: "modify", path: "/p/src/a.ts" }, { operation: "add", path: "/p/src/b.ts" }], patch: { format: "git_patch", text: patch } }],
    },
  ]);
  assert.deepEqual((state.items[0] as ToolCallItem).diffs, [
    { path: "/p/src/a.ts", oldText: "keep\nold\ntail\n", newText: "keep\nnew\nmore\ntail\n", added: 2, removed: 1 },
    { path: "/p/src/b.ts", oldText: null, newText: "created\n", added: 1, removed: 0 },
  ]);
});

test("v2: a diff without a patch still names its files", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call_update", toolCallId: "e1", content: [{ type: "diff", changes: [{ operation: "delete", path: "/p/gone.ts" }] }] },
  ]);
  assert.deepEqual((state.items[0] as ToolCallItem).diffs.map((diff) => diff.path), ["/p/gone.ts"]);
});

test("v2: tool call content chunks add to the call's content", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "tool_call_update", toolCallId: "t1", content: [{ type: "content", content: { type: "text", text: "a" } }] },
    { sessionUpdate: "tool_call_content_chunk", toolCallId: "t1", content: { type: "content", content: { type: "text", text: "b" } } },
  ]);
  assert.equal((state.items[0] as ToolCallItem).output, "a\nb");
});

test("v2: plan_update replaces the plan like plan did", () => {
  const entries = [{ content: "Step", priority: "high" as const, status: "pending" as const }];
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "plan_update", plan: { type: "items", planId: "plan", entries } },
    { sessionUpdate: "plan_update", plan: { type: "items", planId: "plan", entries: [{ ...entries[0], status: "completed" }] } },
  ]);
  assert.equal(state.items.length, 1);
  assert.equal(state.plan?.entries[0].status, "completed");
  applyUpdate(state, { sessionUpdate: "plan_removed" });
  assert.deepEqual([state.items.length, state.plan], [0, null]);
});

test("v2: a sub-agent's session nests as a sub-agent call with its calls and report, its words and usage stay out", () => {
  const state = applyUpdates(emptyConversation(), [
    { sessionUpdate: "usage_update", used: 10, size: 100 },
    { sessionUpdate: "subagent_update", sessionId: "child", title: "Find the bug", description: "Explore", state: { state: "running" } },
    { sessionUpdate: "tool_call_update", toolCallId: "c1", title: "Read a.ts", kind: "read", status: "completed", childSession: "child" },
    { sessionUpdate: "agent_message_chunk", messageId: "m", content: { type: "text", text: "thinking aloud" }, childSession: "child" },
    { sessionUpdate: "usage_update", used: 90, size: 100, childSession: "child" },
    { sessionUpdate: "session_message", messageId: "launch:reply", senderSessionId: "child", recipientSessionId: "root", content: [{ type: "text", text: "Found it." }] },
    { sessionUpdate: "state_update", state: "idle", stopReason: "end_turn", childSession: "child" },
  ]);
  assert.equal(state.items.length, 1);
  const call = state.items[0] as ToolCallItem;
  assert.deepEqual(
    [call.title, call.rawInput, call.children.map((child) => child.title), call.output, call.status, state.usage?.used],
    ["Find the bug", { subagent_type: "Explore", description: "Find the bug" }, ["Read a.ts"], "Found it.", "completed", 10],
  );
});

test("v2: config options read configId as id and flatten grouped values", () => {
  const state = applyUpdates(emptyConversation(), [
    {
      sessionUpdate: "config_option_update",
      configOptions: [
        { configId: "model", name: "Model", category: "model", currentValue: "a", options: [{ groupId: "g", name: "G", options: [{ value: "a", name: "A" }, { value: "b", name: "B" }] }] },
      ] as never,
    },
  ]);
  assert.deepEqual([state.configOptions[0].id, state.configOptions[0].options.map((option) => option.value)], ["model", ["a", "b"]]);
});

test("v2: a turn the agent started keeps its duration when the thread is replayed from disk", async () => {
  const { openConversation } = await import("./conversationThread");
  const conversation = openConversation(
    {
      tabId: "t",
      agentId: "a",
      cwd: "/",
      checkpoints: [],
      updates: [
        { sessionUpdate: "state_update", state: "running", background: [], at: 1000 },
        agentText("Finished."),
        { sessionUpdate: "state_update", state: "idle", background: [] },
        { sessionUpdate: "lilo_turn_end", stopReason: "end_turn", at: 4000 },
      ],
    } as never,
    [],
  );
  const end = conversation.thread.items.at(-1);
  assert.deepEqual([end?.kind, end?.kind === "turnEnd" && end.durationMs], ["turnEnd", 3000]);
});
