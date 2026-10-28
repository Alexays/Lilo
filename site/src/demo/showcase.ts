import { tick } from "svelte";

import { waitForAgent } from "./agent.ts";
import type { DemoHost } from "./host.ts";
import { getPlayground } from "./playground.ts";
import { pageProjects } from "./world.ts";

const waitForElement = <T extends HTMLElement>(
  selector: string,
  signal: AbortSignal
): Promise<T> => {
  signal.throwIfAborted();
  const element = document.querySelector<T>(selector);

  if (element) {
    return Promise.resolve(element);
  }

  const pending = Promise.withResolvers<T>();
  const cleanup = new AbortController();

  const observer = new MutationObserver(() => {
    const match = document.querySelector<T>(selector);

    if (match) {
      pending.resolve(match);
    }
  });

  observer.observe(document.body, {
    attributes: true,
    childList: true,
    subtree: true,
  });
  signal.addEventListener("abort", () => pending.reject(signal.reason), {
    once: true,
    signal: cleanup.signal,
  });

  return pending.promise.finally(() => {
    observer.disconnect();
    cleanup.abort();
  });
};

const typeCommand = async (
  input: HTMLInputElement,
  command: string,
  signal: AbortSignal
) => {
  for (let length = 1; length <= command.length; length += 1) {
    signal.throwIfAborted();
    input.value = command.slice(0, length);
    input.dispatchEvent(new InputEvent("input", { bubbles: true }));
    // oxlint-disable-next-line no-await-in-loop -- Show one character at a time, with cancellable timing.
    await waitForAgent(28, signal);
  }
};

export const createShowcase = (
  host: DemoHost,
  mode: "terminal" | "mcp",
  reloadPage: (tabId: string) => void
) => {
  const playground = getPlayground(host);
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const readmePath = "/Users/you/Projects/lilo/README.md";
  let originalReadme: string | undefined;
  let visible = false;
  let handedOver = false;
  let fresh = true;
  let completed = false;
  let cycle = 0;
  let commandIndex = 0;
  let controller: AbortController | undefined;
  document.documentElement.dataset.showcase = "idle";

  const canRun = () =>
    visible && !document.hidden && !reduceMotion.matches && !handedOver;

  const prepare = async (signal: AbortSignal) => {
    if (mode === "terminal") {
      await waitForElement(".terminal input", signal);
      originalReadme ??= await playground.shell.fs.readFile(readmePath);
      signal.throwIfAborted();
      await playground.shell.fs.writeFile(readmePath, originalReadme);
      await playground.exec(host.snapshot().activeTabId, "clear", signal);
    } else {
      await waitForElement(".agent-session .run:not([disabled])", signal);

      const project = host
        .snapshot()
        .tabs.find((tab) => tab.url.startsWith("https://studio.example.com/"));

      if (project) {
        pageProjects.delete(project.id);
        reloadPage(project.id);
        await tick();
      }
    }
  };

  const terminal = async (signal: AbortSignal) => {
    const input = await waitForElement<HTMLInputElement>(
      ".terminal input",
      signal
    );

    const tabId = host.snapshot().activeTabId;

    const commands = [
      "ls",
      "cat notes/todo.md",
      "printf '# Built in Lilo\\n' > README.md",
      "cat README.md | tr '[:lower:]' '[:upper:]'",
      "cat project.json | jq .",
    ];

    await waitForAgent(600, signal);

    while (commandIndex < commands.length) {
      const command = commands[commandIndex];
      // oxlint-disable-next-line no-await-in-loop -- Preserve the current command when visibility pauses playback.
      await typeCommand(input, command, signal);
      input.value = "";
      input.dispatchEvent(new InputEvent("input", { bubbles: true }));
      // oxlint-disable-next-line no-await-in-loop
      await playground.exec(tabId, command, signal);
      signal.throwIfAborted();
      commandIndex += 1;
      // oxlint-disable-next-line no-await-in-loop
      await waitForAgent(900, signal);
    }
  };

  const agent = async (signal: AbortSignal) => {
    await waitForElement(".agent-session .run:not([disabled])", signal);
    await waitForAgent(600, signal);
    const pending = playground.agent.start();

    try {
      const allow = await waitForElement<HTMLButtonElement>(
        ".prompt-actions .primary",
        signal
      );

      await waitForAgent(1500, signal);
      allow.click();
    } finally {
      // Finish cancellation before a quick scroll back can start another session.
      await pending;
    }

    signal.throwIfAborted();
  };

  const run = async (signal: AbortSignal): Promise<void> => {
    try {
      while (canRun()) {
        if (completed) {
          document.documentElement.dataset.showcase = "done";
          // oxlint-disable-next-line no-await-in-loop -- Keep the finished result visible before replaying.
          await waitForAgent(2500, signal);
          fresh = true;
          completed = false;
          commandIndex = 0;
        }

        document.documentElement.dataset.showcase = "running";

        if (fresh) {
          // oxlint-disable-next-line no-await-in-loop
          await prepare(signal);
          signal.throwIfAborted();
          fresh = false;
          cycle += 1;
          document.documentElement.dataset.showcaseCycle = String(cycle);
        }

        // oxlint-disable-next-line no-await-in-loop
        await (mode === "terminal" ? terminal(signal) : agent(signal));
        signal.throwIfAborted();
        completed = true;
      }
    } catch (error) {
      if (!signal.aborted && error instanceof Error) {
        host.showNotice(error.message);
        handedOver = true;
        playground.agent.stop();
        document.documentElement.dataset.showcase = "stopped";
      }
    } finally {
      controller = undefined;

      if (canRun()) {
        controller = new AbortController();
        void run(controller.signal);
      }
    }
  };

  const sync = (): void => {
    if (canRun()) {
      if (!controller) {
        controller = new AbortController();
        void run(controller.signal);
      }
    } else {
      controller?.abort();
      playground.agent.stop();

      if (!handedOver && (controller || cycle > 0)) {
        document.documentElement.dataset.showcase = "paused";
      }
    }
  };

  const stop = () => {
    handedOver = true;
    controller?.abort();
    document.documentElement.dataset.showcase = "stopped";
  };

  const handOver = (event: Event) => {
    if (event.isTrusted) {
      stop();
    }
  };

  document.addEventListener("pointerdown", handOver, true);
  document.addEventListener("keydown", handOver, true);
  document.addEventListener("visibilitychange", sync);
  reduceMotion.addEventListener("change", sync);

  return {
    setVisible: (next: boolean) => {
      visible = next;
      sync();
    },
    stop,
  };
};

export type Showcase = ReturnType<typeof createShowcase>;
