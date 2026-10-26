<script lang="ts">
import type { Terminal } from "@xterm/xterm";
import type { FitAddon } from "@xterm/addon-fit";
import { onMount, tick, untrack } from "svelte";
import "@xterm/xterm/css/xterm.css";

import type { BridgeTabSnapshot } from "../../../lilo-ui/src/lib/bridge/protocol";
import { getSetting, getTerminalOptions } from "../../../lilo-ui/src/stores/settings.svelte";
import type { DemoHost } from "./host.ts";
import { getPlayground } from "./playground.ts";
import { demoTerminalOptions } from "./settings-state.ts";
import type { ShellEntry } from "./shell.ts";
import { demoCopy } from "./world.ts";
import type { DemoLocale } from "./world.ts";

interface Props {
  host: DemoHost;
  locale: DemoLocale;
  tab: BridgeTabSnapshot;
}

let { host, locale, tab }: Props = $props();
const text = $derived(demoCopy(locale));
const playground = untrack(() => getPlayground(host));
const session = untrack(() => playground.shell.session(tab.id));
let command = $state("");
let cwd = $state(session.cwd);
let running = $state(session.running);
let commandInput: HTMLInputElement | undefined = $state();
let outputElement: HTMLDivElement | undefined = $state();
let terminal = $state.raw<Terminal>();
let fit: FitAddon | undefined;
let dark = $state(typeof document !== "undefined" && document.documentElement.style.colorScheme === "dark");
let lastEntry: ShellEntry | undefined;
let historyPosition = Number.POSITIVE_INFINITY;
let historyDraft = "";
const prompt = $derived(cwd.replace(/^\/Users\/you(?=\/|$)/u, "~"));
const fontFamily = $derived(getSetting("terminalFontFamily", "") ? `"${getSetting("terminalFontFamily", "")}", ui-monospace, monospace` : 'ui-monospace, "SF Mono", Menlo, monospace');
const fontSize = $derived(Math.min(36, Math.max(8, Number(getSetting("terminalFontSize", "13")) || 13)));
const themeId = $derived(getSetting("terminalTheme", "auto"));
const theme = $derived((themeId === "auto" ? undefined : getTerminalOptions()?.themes.find((candidate) => candidate.id === themeId)) ?? demoTerminalOptions(dark).themes[0]);

// xterm bounds scrollback by lines; use a conservative row size for the native byte budget.
const scrollback = $derived(Math.floor(Math.min(100_000, Math.max(1000, (Number(getSetting("terminalScrollbackMB", "10")) || 10) * 1_000_000 / 512))));

const terminalTheme = $derived({
  background: theme.background, black: theme.palette[0], blue: theme.palette[4], brightBlack: theme.palette[8], brightBlue: theme.palette[12], brightCyan: theme.palette[14], brightGreen: theme.palette[10], brightMagenta: theme.palette[13], brightRed: theme.palette[9], brightWhite: theme.palette[15], brightYellow: theme.palette[11], cursor: theme.foreground, cyan: theme.palette[6], foreground: theme.foreground, green: theme.palette[2], magenta: theme.palette[5], red: theme.palette[1], selectionBackground: `${theme.palette[4]}55`, white: theme.palette[7], yellow: theme.palette[3],
});

$effect(() => {
  if (!terminal) {return;}

  terminal.options = { fontFamily, fontSize, scrollback, theme: terminalTheme };

  if (outputElement?.clientWidth && outputElement.clientHeight) {fit?.fit();}
});

const refresh = () => {
  ({ cwd, running } = session);

  if (!terminal) {
    return;
  }

  const entries = session.transcript;
  const latest = entries.at(-1);

  if (latest === lastEntry) {
    return;
  }

  const start = lastEntry ? entries.indexOf(lastEntry) + 1 : 0;

  for (const entry of entries.slice(start)) {
    terminal.write(`${entry.cwd} % ${entry.command}\n${entry.stdout}${entry.stderr}`);
  }

  lastEntry = latest;
};

const runCommand = (event: SubmitEvent) => {
  event.preventDefault();

  if (!command.trim() || session.running) {
    return;
  }

  const source = command;
  command = "";
  historyDraft = "";
  historyPosition = Number.POSITIVE_INFINITY;
  void playground.exec(tab.id, source);
};

const commandKeydown = (event: KeyboardEvent) => {
  if (event.isComposing) {
    return;
  }

  if (event.ctrlKey && event.key.toLowerCase() === "c" && running) {
    event.preventDefault();
    playground.cancel(tab.id);

    return;
  }

  if (
    running || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey ||
    (event.key !== "ArrowUp" && event.key !== "ArrowDown")
  ) {
    return;
  }

  const {history} = session;

  if (!history.length) {
    return;
  }

  event.preventDefault();

  if (historyPosition >= history.length) {
    historyDraft = command;
    historyPosition = history.length;
  }

  historyPosition = event.key === "ArrowUp"
    ? Math.max(0, historyPosition - 1)
    : Math.min(history.length, historyPosition + 1);
  command = history[historyPosition] ?? historyDraft;
  void tick().then(() => commandInput?.setSelectionRange(command.length, command.length));
};

const focusInput = (event: PointerEvent) => {
  if (
    event.button === 0 &&
    !terminal?.hasSelection() &&
    !window.getSelection()?.toString()
  ) {
    commandInput?.focus({ preventScroll: true });
  }
};

onMount(() => {
  const target = outputElement;
  const appearance = matchMedia("(prefers-color-scheme: dark)");
  const updateAppearance = () => { dark = appearance.matches; };

  updateAppearance();
  appearance.addEventListener("change", updateAppearance);

  if (!getTerminalOptions()) {host.dispatch("getTerminalOptions", {});}

  if (!target) {
    return () => appearance.removeEventListener("change", updateAppearance);
  }

  let disposed = false;
  let observer: ResizeObserver | undefined;
  const unsubscribe = playground.subscribe(refresh);
  refresh();

  if (host.snapshot().activeTabId === tab.id && !window.getSelection()?.toString()) {
    commandInput?.focus({ preventScroll: true });
  }

  const openTerminal = async () => {
      const [{ Terminal: Xterm }, { FitAddon }] = await Promise.all([
        import("@xterm/xterm"),
        import("@xterm/addon-fit"),
      ]);

      if (disposed) {
        return;
      }

      terminal = new Xterm({
        convertEol: true,
        cursorBlink: false,
        cursorInactiveStyle: "none",
        disableStdin: true,
        fontFamily,
        fontSize,
        lineHeight: 1.5,
        linkHandler: { activate: (_event, uri) => { if (/^https?:\/\//iu.test(uri)) { host.dispatch("createTab", { url: uri }); } } },
        screenReaderMode: true,
        scrollback,
        theme: terminalTheme,
      });
      fit = new FitAddon();
      terminal.loadAddon(fit);
      terminal.open(target);

      if (terminal.textarea) {
        terminal.textarea.tabIndex = -1;
      }

      fit.fit();
      terminal.write(session.output);
      lastEntry = session.transcript.at(-1);
      observer = new ResizeObserver(() => {
        if (target.clientWidth && target.clientHeight) {
          fit?.fit();
        }
      });
      observer.observe(target);
  };

  void openTerminal();

  return () => {
    disposed = true;
    appearance.removeEventListener("change", updateAppearance);
    unsubscribe();
    observer?.disconnect();
    terminal?.dispose();
    terminal = undefined;
  };
});
</script>

<section class="terminal" aria-label={text.terminal} onpointerup={focusInput} style:background={theme.background} style:color={theme.foreground} style:font-family={fontFamily} style:font-size={`${fontSize}px`} style:--terminal-prompt={theme.palette[2]} style:--terminal-accent={theme.palette[4]}>
  <header>
    <p class="terminal-heading">{text.terminalWelcome}</p>
    <p class="terminal-help">{text.terminalHelp}</p>
  </header>
  <div class="terminal-output" bind:this={outputElement}></div>
  <form onsubmit={runCommand} aria-busy={running}>
    <label for={`command-${tab.id}`} title={cwd}><span>{prompt}</span> <b aria-hidden="true">%</b></label>
    <input
      id={`command-${tab.id}`}
      aria-label={text.terminalInput}
      autocomplete="off"
      autocapitalize="off"
      bind:this={commandInput}
      bind:value={command}
      oninput={() => { historyPosition = Number.POSITIVE_INFINITY; }}
      onkeydown={commandKeydown}
      readonly={running}
      spellcheck={false}
    />
  </form>
</section>

<style>
  .terminal {
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    gap: 18px;
    height: 100%;
    min-height: 0;
    padding: 24px;
    font: 13px/1.5 ui-monospace, "SF Mono", Menlo, monospace;
  }

  p { margin: 0; }
  .terminal-heading { color: var(--terminal-prompt); }
  .terminal-help { margin-top: 8px; color: color-mix(in srgb, currentColor 75%, transparent); }
  .terminal-output { flex: 1; min-height: 0; overflow: hidden; }
  .terminal-output :global(.xterm) { height: 100%; }

  form {
    display: flex;
    flex-shrink: 0;
    align-items: baseline;
    gap: 8px;
    min-width: 0;
  }

  label { display: flex; gap: 8px; max-width: 55%; min-width: 0; color: var(--terminal-accent); white-space: nowrap; }
  label span { overflow: hidden; text-overflow: ellipsis; }
  label b { color: var(--terminal-prompt); font-weight: 400; }

  input {
    flex: 1;
    min-width: 0;
    border: 0;
    padding: 5px 0;
    background: transparent;
    color: inherit;
    caret-color: currentColor;
    font: inherit;
  }

  input:focus-visible { outline: 2px solid var(--terminal-accent); outline-offset: 4px; border-radius: 2px; }
  input[readonly] { cursor: progress; }

  @media (max-width: 600px) { .terminal { gap: 14px; padding: 18px; } }
</style>
