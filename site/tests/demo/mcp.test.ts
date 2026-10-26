import assert from "node:assert/strict";
import { test } from "node:test";

import * as z from "zod/v4";

import { createDemoHost } from "../../src/demo/host.ts";
import { connectMcp } from "../../src/demo/mcp.ts";

const resultText = (
  result: Awaited<ReturnType<Awaited<ReturnType<typeof connectMcp>>["call"]>>
) =>
  result.content
    .filter((content) => content.type === "text")
    .map((content) => content.text)
    .join("\n");

test("MCP performs a real initialize and tools/list exchange", async (context) => {
  const host = createDemoHost("en");
  const connection = await connectMcp(host);
  context.after(() => connection.close());
  assert.equal(connection.serverInfo?.name, "lilo");
  const tools = await connection.list();
  assert.ok(tools.tools.some((tool) => tool.name === "navigate"));
  assert.ok(tools.tools.some((tool) => tool.name === "read_page"));
  assert.ok(tools.tools.some((tool) => tool.name === "form_input"));
  assert.equal(
    tools.tools.some((tool) => tool.name === "javascript_tool"),
    false
  );
});

test("MCP creates and navigates only agent-owned tabs while personal tabs stay unchanged", async (context) => {
  const host = createDemoHost("en");
  const personal = host.snapshot().tabs;
  const connection = await connectMcp(host);
  context.after(() => connection.close());
  const created = await connection.call("tabs_create_mcp", {});

  const { tabId } = z
    .object({ tabId: z.number() })
    .parse(JSON.parse(resultText(created)));

  const navigated = await connection.call("navigate", {
    tabId,
    url: "https://project.example.com",
  });

  assert.equal(navigated.isError, undefined);
  assert.ok(
    host.agentTabs().some((tab) => tab.url === "https://project.example.com/")
  );
  const listing = resultText(await connection.call("tabs_context_mcp", {}));
  assert.equal(listing.includes("github.com/Alexays/Lilo"), false);
  host.openBrowser();
  assert.deepEqual(host.snapshot().tabs, personal);
  await connection.call("tabs_close_mcp", { tabId });

  const denied = await connection.call("navigate", {
    tabId,
    url: "https://notes.example.com",
  });

  assert.equal(denied.isError, true);
});

test("MCP schema errors and unknown tab IDs cannot mutate the browser state", async (context) => {
  const host = createDemoHost("en");
  const connection = await connectMcp(host);
  context.after(() => connection.close());
  const before = host.agentTabs();

  const malformed = await connection.call("navigate", {
    tabId: "1",
    url: "https://notes.example.com",
  });

  assert.equal(malformed.isError, true);

  const outside = await connection.call("navigate", {
    tabId: 999,
    url: "https://notes.example.com",
  });

  assert.equal(outside.isError, true);

  const reserved = await connection.call("navigate", {
    tabId: 1,
    url: "https://mcp.example.com",
  });

  assert.equal(reserved.isError, true);
  assert.deepEqual(host.agentTabs(), before);
});

test("locked agent folders stay hidden through toolbar reopening and MCP calls", async (context) => {
  const host = createDemoHost("en");
  const connection = await connectMcp(host);
  context.after(() => connection.close());
  const [tab] = host.agentTabs();
  assert.ok(tab);
  host.dispatch("setTabFolderLock", {
    allowsBiometrics: false,
    id: "playground-client",
    password: "sample-password",
  });
  const before = host.snapshot();
  host.openPlayground("mcp");
  host.openPlayground("terminal");
  assert.deepEqual(host.snapshot(), before);
  assert.equal(host.agentTabs().length, 0);
  assert.equal(host.snapshot().splitIds.includes(tab.id), false);

  const denied = await connection.call("navigate", {
    tabId: 1,
    url: "https://notes.example.com",
  });

  assert.equal(denied.isError, true);
  const created = await connection.call("tabs_create_mcp", {});
  assert.equal(created.isError, true);
  assert.equal(host.agentTabs().length, 0);
  host.dispatch("unlockTabFolder", {
    id: "playground-client",
    password: "sample-password",
  });
  assert.equal(host.agentTabs().length, 1);
});

test("turning agent access off blocks tools before they change the sample browser", async (context) => {
  const host = createDemoHost("en");
  const connection = await connectMcp(host);
  context.after(() => connection.close());
  const before = host.agentTabs();
  host.dispatch("setSetting", { key: "agentControlEnabled", value: "false" });
  await assert.rejects(
    connection.call("tabs_create_mcp", {}),
    /access is turned off/u
  );
  assert.deepEqual(host.agentTabs(), before);
  host.dispatch("setSetting", { key: "agentControlEnabled", value: "true" });
  const created = await connection.call("tabs_create_mcp", {});
  assert.equal(created.isError, undefined);
  assert.equal(host.agentTabs().length, before.length + 1);
});
