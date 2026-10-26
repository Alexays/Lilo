import assert from "node:assert/strict";
import { test } from "node:test";

import type { AnyBridgeEventEnvelope } from "../../../lilo-ui/src/lib/bridge/protocol";
import { waitForAgent } from "../../src/demo/agent.ts";
import { createDemoHost } from "../../src/demo/host.ts";

const action = {
  kind: "click",
  label: "Publish update",
  site: "studio.example.com",
  tab: "Website launch",
} as const;

test("agent permission resolves only its own response and remembers only a matching allowed site", async () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const host = createDemoHost("en", (event) => events.push(event));
  const { signal } = new AbortController();
  const pending = host.requestAgentApproval(action, signal);

  const request = events.findLast(
    (event) => event.event === "agentControlRequested"
  );

  assert.ok(request);
  assert.equal(request.clientName, "Codex");
  host.dispatch("agentControlResponse", {
    granted: false,
    requestId: "other-request",
  });
  host.dispatch("agentControlResponse", {
    alwaysAllowSite: "other.example.com",
    granted: true,
    requestId: request.requestId,
  });
  assert.equal(await pending, true);

  const second = host.requestAgentApproval(action, signal);

  const nextRequest = events.findLast(
    (event) => event.event === "agentControlRequested"
  );

  assert.ok(nextRequest);
  assert.notEqual(nextRequest.requestId, request.requestId);
  host.dispatch("agentControlResponse", {
    alwaysAllowSite: action.site,
    granted: true,
    requestId: nextRequest.requestId,
  });
  assert.equal(await second, true);
  const count = events.length;
  assert.equal(await host.requestAgentApproval(action, signal), true);
  assert.equal(events.length, count);
});

test("canceling an agent permission dismisses the native prompt and ignores a late Allow", async () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const host = createDemoHost("en", (event) => events.push(event));
  const controller = new AbortController();
  const pending = host.requestAgentApproval(action, controller.signal);

  const request = events.findLast(
    (event) => event.event === "agentControlRequested"
  );

  assert.ok(request);
  controller.abort();
  assert.equal(await pending, false);
  assert.deepEqual(events.at(-1), {
    event: "permissionRequestClosed",
    requestId: request.requestId,
  });
  host.dispatch("agentControlResponse", {
    alwaysAllowSite: action.site,
    granted: true,
    requestId: request.requestId,
  });

  const next = host.requestAgentApproval(action, new AbortController().signal);

  const nextRequest = events.findLast(
    (event) => event.event === "agentControlRequested"
  );

  assert.ok(nextRequest);
  assert.notEqual(nextRequest.requestId, request.requestId);
  host.dispatch("agentControlResponse", {
    granted: false,
    requestId: nextRequest.requestId,
  });
  assert.equal(await next, false);
});

test("the agent frame cannot target a personal tab and is removed when work stops", () => {
  const host = createDemoHost("en");
  const personal = host.snapshot().activeTabId;
  host.openPlayground("mcp");
  host.setAgentSession(true);
  host.presentAgent(personal, { pressed: true, x: 10, y: 20 });
  assert.equal(host.snapshot().agentControl, null);
  const [owned] = host.agentTabs();
  assert.ok(owned);
  host.presentAgent(owned.id, { pressed: true, x: 10, y: 20 });
  assert.equal(host.snapshot().agentControl?.tabId, owned.id);
  host.setAgentSession(false);
  assert.equal(host.snapshot().agentControl, null);
});

test("agent pacing cancels immediately instead of leaving a timer running", async () => {
  const controller = new AbortController();
  const pending = waitForAgent(60_000, controller.signal);
  controller.abort();
  await assert.rejects(pending, { name: "AbortError" });
  assert.throws(() => waitForAgent(0, controller.signal), {
    name: "AbortError",
  });
});
