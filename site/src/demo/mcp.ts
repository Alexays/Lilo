import { Client, InMemoryTransport } from "@modelcontextprotocol/client";
import { McpServer } from "@modelcontextprotocol/server";
import type { CallToolResult } from "@modelcontextprotocol/server";
import { CfWorkerJsonSchemaValidator } from "@modelcontextprotocol/server/validators/cf-worker";
import { tick } from "svelte";
import * as z from "zod/v4";

import { waitForAgent } from "./agent.ts";
import type { DemoHost } from "./host.ts";

// The demo's CSP excludes generated JavaScript, including schema-validator JITs.
z.config({ jitless: true });

const textResult = (text: string): CallToolResult => ({
  content: [{ text, type: "text" }],
});

const tabSchema = z.number().int().positive();

const readable =
  "h1,h2,h3,p,button,a,input,textarea,select,[role=button],[role=checkbox]";

const elementName = (element: HTMLElement) => {
  const label = element.getAttribute("aria-label");

  if (label) {
    return label;
  }

  if (
    element instanceof HTMLInputElement ||
    element instanceof HTMLTextAreaElement ||
    element instanceof HTMLSelectElement
  ) {
    const labels = [...(element.labels ?? [])]
      .map((item) => item.textContent)
      .join(" ")
      .trim();

    return (
      labels ||
      element.getAttribute("placeholder") ||
      element.name ||
      element.value
    );
  }

  return (element.textContent ?? "")
    .replaceAll(/\s+/gu, " ")
    .trim()
    .slice(0, 180);
};

const elementRole = (element: HTMLElement) =>
  (element instanceof HTMLInputElement && element.type === "checkbox"
    ? "checkbox"
    : element.getAttribute("role")) ??
  new Map([
    ["BUTTON", "button"],
    ["A", "link"],
    ["INPUT", "textbox"],
    ["TEXTAREA", "textbox"],
    ["SELECT", "combobox"],
    ["H1", "heading"],
    ["H2", "heading"],
    ["H3", "heading"],
  ]).get(element.tagName) ??
  "text";

const elements = (root: HTMLElement) =>
  [...root.querySelectorAll<HTMLElement>(readable)].filter(
    (element) => element.getClientRects().length > 0
  );

export const connectMcp = async (host: DemoHost) => {
  if (!host.agentTabs().length) {
    host.openPlayground("mcp");
  }

  const server = new McpServer(
    { name: "lilo", version: host.snapshot().settings.appVersion },
    { jsonSchemaValidator: new CfWorkerJsonSchemaValidator() }
  );

  const client = new Client(
    { name: "Codex demo", version: "1.0.0" },
    { jsonSchemaValidator: new CfWorkerJsonSchemaValidator() }
  );

  const tabs = new Map<number, string>();
  const references = new Map<number, Map<string, HTMLElement>>();
  const elementRefs = new WeakMap<HTMLElement, string>();
  let nextTabId = 0;
  let nextRef = 0;
  let activeCalls = 0;

  const registerTab = (id: string) => {
    for (const [number, existing] of tabs) {
      if (existing === id) {
        return number;
      }
    }

    nextTabId += 1;
    tabs.set(nextTabId, id);

    return nextTabId;
  };

  for (const tab of host.agentTabs()) {
    registerTab(tab.id);
  }

  const ownTab = (tabId: number) => {
    const id = tabs.get(tabId);
    const tab = host.agentTabs().find((item) => item.id === id);

    if (!tab) {
      throw new Error(`Tab ${tabId} does not belong to this playground agent.`);
    }

    return tab;
  };

  const pageReady = (tabId: number, root: HTMLElement) => {
    const table = references.get(tabId);

    if (table) {
      for (const [ref, element] of table) {
        if (!root.contains(element)) {
          table.delete(ref);
        }
      }
    }

    return root;
  };

  const pageFor = async (tabId: number, signal: AbortSignal) => {
    const tab = ownTab(tabId);
    host.showAgentTab(tab.id);

    if (host.isAgentSessionActive()) {
      host.dispatch("switchTab", { id: tab.id });
      host.presentAgent(tab.id);
    }

    await tick();

    const query = () => {
      const root = document.querySelector<HTMLElement>(
        `[data-sample-tab="${CSS.escape(tab.id)}"] .page`
      );

      if (root?.querySelector('[data-page-loading="true"]')) {
        return null;
      }

      return root;
    };

    const root = query();

    if (root) {
      return pageReady(tabId, root);
    }

    const pending = Promise.withResolvers<HTMLElement>();
    const cleanup = new AbortController();

    const observer = new MutationObserver(() => {
      const found = query();

      if (found) {
        observer.disconnect();
        cleanup.abort();
        pending.resolve(pageReady(tabId, found));
      }
    });

    observer.observe(document.body, {
      attributes: true,
      childList: true,
      subtree: true,
    });

    const abort = () => {
      observer.disconnect();
      cleanup.abort();
      pending.reject(new Error("Page request canceled."));
    };

    if (signal.aborted) {
      abort();
    } else {
      signal.addEventListener("abort", abort, {
        once: true,
        signal: cleanup.signal,
      });
    }

    return pending.promise;
  };

  const refFor = (tabId: number, element: HTMLElement) => {
    const table = references.get(tabId) ?? new Map<string, HTMLElement>();
    references.set(tabId, table);
    let ref = elementRefs.get(element);

    if (!ref) {
      nextRef += 1;
      ref = `ref_${nextRef}`;
      elementRefs.set(element, ref);
    }

    table.set(ref, element);

    return ref;
  };

  const resolveRef = async (
    tabId: number,
    ref: string,
    signal: AbortSignal
  ) => {
    const root = await pageFor(tabId, signal);
    const element = references.get(tabId)?.get(ref);

    if (!element || !root.contains(element) || !element.isConnected) {
      throw new Error(
        `Unknown or expired element ref: ${ref}. Read the page again.`
      );
    }

    return element;
  };

  const pointAt = async (
    tabId: number,
    element: HTMLElement,
    signal: AbortSignal,
    pressed = false
  ) => {
    signal.throwIfAborted();

    if (!host.isAgentSessionActive()) {
      return;
    }

    element.scrollIntoView({
      behavior: "instant",
      block: "nearest",
      inline: "nearest",
    });
    await tick();
    const pane = element.closest<HTMLElement>("[data-sample-tab]");

    if (!pane) {
      throw new Error("The sample tab is no longer visible.");
    }

    const rect = element.getBoundingClientRect();
    const bounds = pane.getBoundingClientRect();
    host.presentAgent(ownTab(tabId).id, {
      pressed,
      x: rect.left - bounds.left + Math.min(rect.width / 2, 80),
      y: rect.top - bounds.top + rect.height / 2,
    });

    if (!pressed) {
      await waitForAgent(
        matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 180,
        signal
      );
    }
  };

  server.registerTool(
    "tabs_context_mcp",
    {
      description:
        "List this playground agent's sample tabs. Personal demo tabs are outside this session.",
      inputSchema: z.strictObject({
        createIfEmpty: z.boolean().optional(),
        title: z.string().max(80).optional(),
      }),
    },
    ({ createIfEmpty, title }) => {
      if (createIfEmpty && !host.agentTabs().length) {
        host.createAgentTab();
      }

      if (title) {
        host.nameAgentGroup(title);
      }

      return textResult(
        JSON.stringify(
          {
            tabs: host.agentTabs().map((tab) => ({
              id: registerTab(tab.id),
              title: tab.title,
              url: tab.url,
            })),
          },
          null,
          2
        )
      );
    }
  );
  server.registerTool(
    "tabs_create_mcp",
    {
      description: "Create a sample tab in the agent's own Space.",
      inputSchema: z.strictObject({ title: z.string().max(80).optional() }),
    },
    ({ title }) => {
      const tab = host.createAgentTab();

      if (title) {
        host.nameAgentGroup(title);
      }

      return textResult(JSON.stringify({ tabId: registerTab(tab.id) }));
    }
  );
  server.registerTool(
    "tabs_close_mcp",
    {
      description: "Close one of this agent's sample tabs.",
      inputSchema: z.strictObject({ tabId: tabSchema }),
    },
    ({ tabId }) => {
      host.closeAgentTab(ownTab(tabId).id);
      tabs.delete(tabId);
      references.delete(tabId);

      return textResult(`Closed tab ${tabId}`);
    }
  );
  server.registerTool(
    "navigate",
    {
      description:
        "Navigate a sample agent tab. Addresses display local demo pages; no external website is fetched.",
      inputSchema: z.strictObject({
        tabId: tabSchema,
        url: z.string().min(1).max(2048),
      }),
    },
    ({ tabId, url }) => {
      const normalized = /^https?:\/\//iu.test(url) ? url : `https://${url}`;
      const tab = host.navigateAgentTab(ownTab(tabId).id, normalized);
      references.delete(tabId);

      return textResult(
        JSON.stringify({ tabId, title: tab.title, url: tab.url })
      );
    }
  );
  server.registerTool(
    "read_page",
    {
      description:
        "Read roles, labels and element refs from the sample page. Use returned refs with form_input or computer.",
      inputSchema: z.strictObject({
        filter: z.enum(["all", "interactive"]).optional(),
        max_chars: z.number().int().min(100).max(50_000).optional(),
        tabId: tabSchema,
      }),
    },
    async ({ tabId, filter, max_chars }, context) => {
      const root = await pageFor(tabId, context.mcpReq.signal);

      const rows = elements(root).filter(
        (element) =>
          filter !== "interactive" ||
          element.matches(
            "button,a,input,textarea,select,[role=button],[role=checkbox]"
          )
      );

      const result = rows
        .map((element) => {
          let value = "";

          if (
            element instanceof HTMLInputElement &&
            element.type === "checkbox"
          ) {
            value = ` checked=${element.checked}`;
          } else if (
            element instanceof HTMLInputElement ||
            element instanceof HTMLTextAreaElement
          ) {
            value = ` value=${JSON.stringify(element.value)}`;
          }

          return `[${refFor(tabId, element)}] ${elementRole(element)} ${JSON.stringify(elementName(element))}${value}`;
        })
        .join("\n");

      return textResult(result.slice(0, max_chars ?? 20_000));
    }
  );
  server.registerTool(
    "get_page_text",
    {
      description: "Read the current text of a sample page.",
      inputSchema: z.strictObject({
        max_chars: z.number().int().min(100).max(50_000).optional(),
        tabId: tabSchema,
      }),
    },
    async ({ tabId, max_chars }, context) => {
      const root = await pageFor(tabId, context.mcpReq.signal);

      const values = [
        ...root.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>(
          "input,textarea"
        ),
      ]
        .map((element) => element.value)
        .join("\n");

      return textResult(
        `${root.textContent}\n${values}`.trim().slice(0, max_chars ?? 20_000)
      );
    }
  );
  server.registerTool(
    "find",
    {
      description:
        "Find controls or text in a sample page and return element refs.",
      inputSchema: z.strictObject({
        query: z.string().min(1).max(200),
        tabId: tabSchema,
      }),
    },
    async ({ tabId, query }, context) => {
      const root = await pageFor(tabId, context.mcpReq.signal);

      return textResult(
        elements(root)
          .filter((element) =>
            elementName(element).toLowerCase().includes(query.toLowerCase())
          )
          .slice(0, 20)
          .map(
            (element) =>
              `[${refFor(tabId, element)}] ${elementRole(element)} ${JSON.stringify(elementName(element))}`
          )
          .join("\n")
      );
    }
  );
  server.registerTool(
    "form_input",
    {
      description:
        "Edit a sample page field using a ref from read_page or find.",
      inputSchema: z.strictObject({
        ref: z.string().max(80),
        tabId: tabSchema,
        value: z.union([z.string().max(20_000), z.boolean(), z.number()]),
      }),
    },
    async ({ tabId, ref, value }, context) => {
      const element = await resolveRef(tabId, ref, context.mcpReq.signal);
      await pointAt(tabId, element, context.mcpReq.signal);

      if (!element.isConnected) {
        throw new Error("The sample page is no longer visible.");
      }

      if (
        element instanceof HTMLInputElement &&
        (element.type === "checkbox" || element.type === "radio")
      ) {
        element.checked = value === true;
      } else if (
        element instanceof HTMLInputElement ||
        element instanceof HTMLTextAreaElement ||
        element instanceof HTMLSelectElement
      ) {
        const source = String(value);

        if (
          host.isAgentSessionActive() &&
          !matchMedia("(prefers-reduced-motion: reduce)").matches
        ) {
          const chunk = Math.max(1, Math.ceil(source.length / 16));

          for (let end = chunk; end < source.length; end += chunk) {
            context.mcpReq.signal.throwIfAborted();

            if (!element.isConnected) {
              throw new Error("The sample page is no longer visible.");
            }

            element.value = source.slice(0, end);
            element.dispatchEvent(new Event("input", { bubbles: true }));
            // Typing is sequential and yields between chunks so Stop and page input stay responsive.
            // oxlint-disable-next-line no-await-in-loop
            await waitForAgent(24, context.mcpReq.signal);
          }
        }

        context.mcpReq.signal.throwIfAborted();
        element.value = source;
      } else {
        throw new TypeError("That ref is not an editable field.");
      }

      element.dispatchEvent(new Event("input", { bubbles: true }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
      await tick();

      return textResult(`Updated ${ref}`);
    }
  );
  server.registerTool(
    "computer",
    {
      description: "Click a sample page control by its element ref.",
      inputSchema: z.strictObject({
        action: z.literal("left_click"),
        ref: z.string().max(80),
        tabId: tabSchema,
      }),
    },
    async ({ tabId, ref }, context) => {
      const element = await resolveRef(tabId, ref, context.mcpReq.signal);

      if (!element.matches("button,a,input,[role=button],[role=checkbox]")) {
        throw new Error("That ref is not a clickable control.");
      }

      if (element.matches(":disabled")) {
        throw new Error("That control is disabled.");
      }

      await pointAt(tabId, element, context.mcpReq.signal);

      if (Object.hasOwn(element.dataset, "agentApproval")) {
        const tab = ownTab(tabId);

        const granted = await host.requestAgentApproval(
          {
            kind: "click",
            label: elementName(element),
            site: new URL(tab.url).hostname,
            tab: tab.title,
          },
          context.mcpReq.signal
        );

        context.mcpReq.signal.throwIfAborted();

        if (!granted) {
          return {
            ...textResult("Permission denied. The page was not published."),
            isError: true,
            structuredContent: { error: "permission_denied" },
          };
        }
      }

      if (!element.isConnected || element.matches(":disabled")) {
        throw new Error("The page changed before the click.");
      }

      await pointAt(tabId, element, context.mcpReq.signal, true);
      element.click();
      await tick();

      return textResult(`Clicked ${ref}`);
    }
  );

  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await server.connect(serverSide);
  await client.connect(clientSide);
  host.setAgentBusy(false);

  return {
    call: async (
      name: string,
      args: NonNullable<Parameters<Client["callTool"]>[0]["arguments"]>,
      signal?: AbortSignal
    ) => {
      signal?.throwIfAborted();

      if (!host.isAgentControlEnabled()) {
        throw new Error("Agent access is turned off in Settings.");
      }

      const owned = new Set(host.agentTabs().map((tab) => tab.id));

      for (const [tabId, id] of tabs) {
        if (!owned.has(id)) {
          tabs.delete(tabId);
          references.delete(tabId);
        }
      }

      activeCalls += 1;
      const generation = host.agentGeneration();
      host.setAgentBusy(true);

      try {
        return await client.callTool({ arguments: args, name }, { signal });
      } finally {
        activeCalls -= 1;

        if (generation === host.agentGeneration()) {
          host.setAgentBusy(activeCalls > 0);
        }
      }
    },
    close: async () => {
      await client.close();
      await server.close();
    },
    list: (signal?: AbortSignal) => client.listTools(undefined, { signal }),
    serverInfo: client.getServerVersion(),
  };
};

export type McpConnection = Awaited<ReturnType<typeof connectMcp>>;
