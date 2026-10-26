import type { CallToolResult } from "@modelcontextprotocol/server";
import * as z from "zod/v4";

import type { DemoHost } from "./host.ts";
import type { McpConnection } from "./mcp.ts";
import { demoCopy } from "./world.ts";

export const waitForAgent = (ms: number, signal: AbortSignal) => {
  signal.throwIfAborted();

  const pending = Promise.withResolvers<undefined>();
  const cleanup = new AbortController();
  const timer = setTimeout(() => pending.resolve(undefined), ms);
  signal.addEventListener("abort", () => pending.reject(signal.reason), {
    once: true,
    signal: cleanup.signal,
  });

  return pending.promise.finally(() => {
    clearTimeout(timer);
    cleanup.abort();
  });
};

const resultText = (result: CallToolResult) =>
  result.content
    .filter((content) => content.type === "text")
    .map((content) => content.text)
    .join("\n");

interface AgentStep {
  label: string;
  tool: string;
  status: "running" | "done" | "stopped";
}

export interface AgentState {
  status:
    | "idle"
    | "running"
    | "waiting"
    | "done"
    | "denied"
    | "stopped"
    | "error";
  steps: AgentStep[];
}

const failureStatus = (
  message: string,
  signal: AbortSignal
): AgentState["status"] => {
  if (signal.aborted) {
    return "stopped";
  }

  if (message === "permission_denied") {
    return "denied";
  }

  return "error";
};

export const createAgentSession = (
  host: DemoHost,
  connect: () => Promise<McpConnection>
) => {
  let state: AgentState = { status: "idle", steps: [] };
  let controller: AbortController | undefined;
  const listeners = new Set<() => void>();

  const update = (next: AgentState) => {
    state = next;

    for (const listener of listeners) {
      listener();
    }
  };

  const start = async () => {
    if (controller || !host.isAgentControlEnabled()) {
      return;
    }

    controller = new AbortController();
    const { signal } = controller;

    const text = demoCopy(
      host.snapshot().settings.locale === "fr" ? "fr" : "en"
    );

    update({ status: "running", steps: [] });
    host.setAgentSession(true);

    try {
      const connection = await connect();

      const call = async (
        label: string,
        tool: string,
        args: Parameters<McpConnection["call"]>[1],
        waiting = false
      ) => {
        signal.throwIfAborted();
        update({
          status: waiting ? "waiting" : "running",
          steps: [...state.steps, { label, status: "running", tool }],
        });
        await waitForAgent(350, signal);
        const result = await connection.call(tool, args, signal);

        if (result.isError) {
          throw new TypeError(
            z
              .object({ error: z.literal("permission_denied") })
              .safeParse(result.structuredContent).success
              ? "permission_denied"
              : resultText(result)
          );
        }

        signal.throwIfAborted();
        update({
          status: "running",
          steps: state.steps.map((step, index) =>
            index === state.steps.length - 1
              ? { ...step, status: "done" }
              : step
          ),
        });

        return resultText(result);
      };

      const listing = await connection.call(
        "tabs_context_mcp",
        { createIfEmpty: true, title: "Codex" },
        signal
      );

      const context = z
        .object({
          tabs: z.array(z.object({ id: z.number(), url: z.string() })),
        })
        .parse(JSON.parse(resultText(listing)));

      const tabId = (
        context.tabs.find((tab) =>
          tab.url.startsWith("https://studio.example.com/")
        ) ?? context.tabs.at(-1)
      )?.id;

      if (!tabId) {
        throw new Error("No agent tab is available.");
      }

      await call(text.agentOpen, "navigate", {
        tabId,
        url: "https://studio.example.com/launch",
      });

      const page = await call(text.agentRead, "read_page", {
        filter: "interactive",
        tabId,
      });

      const pending = [
        ...page.matchAll(
          /^\[(?<ref>ref_\d+)\] checkbox (?<label>"(?:[^"\\]|\\.)*") checked=false$/gmu
        ),
      ];

      for (const match of pending) {
        const ref = match.groups?.ref;
        const label = z.string().parse(JSON.parse(match.groups?.label ?? '""'));
        // MCP clicks run in order so each visible cursor action finishes before the next begins.
        // oxlint-disable-next-line no-await-in-loop
        await call(`${text.agentCheck}: ${label}`, "computer", {
          action: "left_click",
          ref,
          tabId,
        });
      }

      const field = await call(text.agentWrite, "find", {
        query: text.agentUpdate,
        tabId,
      });

      const fieldRef = field.match(/\[(?<ref>ref_\d+)\] textbox /u)?.groups
        ?.ref;

      if (!fieldRef) {
        throw new Error("The project update field is missing.");
      }

      await call(text.agentWrite, "form_input", {
        ref: fieldRef,
        tabId,
        value: text.agentSummary,
      });

      const publish = await connection.call(
        "find",
        { query: text.agentPublish, tabId },
        signal
      );

      const publishRef = resultText(publish).match(
        /\[(?<ref>ref_\d+)\] button /u
      )?.groups?.ref;

      if (!publishRef) {
        throw new Error("The publish control is missing.");
      }

      await call(
        text.agentPublish,
        "computer",
        { action: "left_click", ref: publishRef, tabId },
        true
      );
      const verified = await call(text.agentVerify, "get_page_text", { tabId });

      if (!verified.includes(text.agentPublished)) {
        throw new Error("The page did not confirm publication.");
      }

      update({ ...state, status: "done" });
    } catch (error) {
      const status = failureStatus(
        error instanceof Error ? error.message : "",
        signal
      );

      update({
        status,
        steps: state.steps.map((step) =>
          step.status === "running" ? { ...step, status: "stopped" } : step
        ),
      });
    } finally {
      host.setAgentSession(false);
      controller = undefined;
    }
  };

  return {
    snapshot: () => state,
    start,
    stop: () => controller?.abort(),
    subscribe: (listener: () => void) => {
      listeners.add(listener);

      return () => listeners.delete(listener);
    },
  };
};
