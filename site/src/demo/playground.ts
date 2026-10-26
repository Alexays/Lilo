import { createAgentSession } from "./agent.ts";
import type { DemoHost } from "./host.ts";
import { connectMcp } from "./mcp.ts";
import type { McpConnection } from "./mcp.ts";
import { createShell } from "./shell.ts";

const createPlayground = (host: DemoHost) => {
  let connection: Promise<McpConnection> | undefined;

  const connect = () => {
    connection ??= connectMcp(host);

    return connection;
  };

  const listeners = new Set<() => void>();
  const controllers = new Map<string, AbortController>();

  const notify = () => {
    for (const listener of listeners) {
      listener();
    }
  };

  const shell = createShell({
    callMcp: async (name, args, signal?: AbortSignal) => {
      notify();
      const session = await connect();
      const response = await session.call(name, args, signal);
      const output = JSON.stringify(response, null, 2);

      if (response.isError) {
        throw new TypeError(output);
      }

      return output;
    },
    listMcp: async (signal?: AbortSignal) => {
      const session = await connect();

      return JSON.stringify(await session.list(signal), null, 2);
    },
  });

  const agent = createAgentSession(host, connect);

  const closeConnection = async (current: Promise<McpConnection>) => {
    try {
      const session = await current;
      await session.close();
    } catch (error) {
      if (error instanceof Error) {
        host.showNotice(error.message);
      }
    }
  };

  host.onStopAgents(() => {
    agent.stop();
    const current = connection;
    connection = undefined;

    if (current) {
      void closeConnection(current);
    }
  });

  return {
    agent,
    cancel: (tabId: string) => controllers.get(tabId)?.abort(),
    connect,
    exec: async (tabId: string, command: string, signal?: AbortSignal) => {
      const session = shell.session(tabId);

      if (session.running) {
        return session.exec(command, signal);
      }

      const controller = new AbortController();
      controllers.set(tabId, controller);
      const abort = () => controller.abort();

      if (signal?.aborted) {
        abort();
      } else {
        signal?.addEventListener("abort", abort, { once: true });
      }

      try {
        const pending = session.exec(command, controller.signal);
        notify();

        return await pending;
      } finally {
        controllers.delete(tabId);
        signal?.removeEventListener("abort", abort);
        notify();
      }
    },
    shell,
    subscribe: (listener: () => void) => {
      listeners.add(listener);

      return () => listeners.delete(listener);
    },
  };
};

const sessions = new WeakMap<DemoHost, ReturnType<typeof createPlayground>>();

export const getPlayground = (host: DemoHost) => {
  let playground = sessions.get(host);

  if (!playground) {
    playground = createPlayground(host);
    sessions.set(host, playground);
  }

  return playground;
};
