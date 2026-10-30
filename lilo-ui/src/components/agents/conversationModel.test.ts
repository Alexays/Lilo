import assert from "node:assert/strict";
import test from "node:test";

import {
  addNotice,
  addPermissionRequest,
  addUserPrompt,
  applyUpdate,
  applyUpdates,
  diffStats,
  emptyConversation,
  endTurn,
  resolvePermission,
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

test("notices are appended", () => {
  const state = addNotice(emptyConversation(), "Files restored");
  assert.deepEqual(state.items, [{ kind: "notice", id: 1, text: "Files restored" }]);
});
