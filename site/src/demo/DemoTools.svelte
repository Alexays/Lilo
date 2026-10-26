<script lang="ts">
  import { onMount } from "svelte";
  import * as z from "zod/v4";
  import type { DemoHost } from "./host.ts";
  import type { McpConnection } from "./mcp.ts";
  import { getPlayground } from "./playground.ts";
  import { demoCopy } from "./world.ts";
  import type { DemoLocale } from "./world.ts";
  import { getSetting } from "../../../lilo-ui/src/stores/settings.svelte";

  let { host, locale }: { host: DemoHost; locale: DemoLocale } = $props();
  const text = $derived(demoCopy(locale));
  let connection = $state<McpConnection>();
  let tools = $state.raw<Awaited<ReturnType<McpConnection["list"]>>["tools"]>([]);
  let selected = $state("read_page");
  let args = $state('{\n  "tabId": 1\n}');
  let result = $state("");
  let error = $state("");
  let running = $state(false);
  let elapsed = $state<number>();
  let pending: AbortController | undefined;
  const enabled = $derived(getSetting("agentControlEnabled", "true") === "true");

  $effect(() => { if (!enabled) { pending?.abort(); } });

  const examples = new Map([
    ["tabs_context_mcp", "{}"], ["tabs_create_mcp", "{}"], ["tabs_close_mcp", '{"tabId":1}'],
    ["navigate", '{"tabId":1,"url":"https://notes.example.com/agents"}'],
    ["read_page", '{"tabId":1}'], ["get_page_text", '{"tabId":1}'],
    ["find", '{"tabId":1,"query":"notes"}'], ["form_input", '{"tabId":1,"ref":"ref_1","value":"Hello from MCP"}'],
    ["computer", '{"tabId":1,"action":"left_click","ref":"ref_1"}'],
  ]);

  const chooseTool = (event: Event & { currentTarget: HTMLSelectElement }) => {
    args = JSON.stringify(JSON.parse(examples.get(event.currentTarget.value) ?? "{}"), null, 2);
    error = "";
  };

  const run = async (event: SubmitEvent) => {
    event.preventDefault();

    if (!connection || running || !enabled) {return;}

    running = true;
    const controller = new AbortController();
    pending = controller;
    error = "";
    const start = performance.now();

    try {
      const parameters = z.record(z.string(), z.json()).parse(JSON.parse(args));
      const response = await connection.call(selected, parameters, controller.signal);
      result = JSON.stringify(response, null, 2);
      elapsed = Math.round(performance.now() - start);
    } catch (error_) {
      error = error_ instanceof Error ? error_.message : String(error_);
    } finally { running = false; pending = undefined; }
  };

  const stopWhenHidden = () => {
      if (document.hidden || document.documentElement.classList.contains("reduced-power")) { pending?.abort(); }
    };


  onMount(() => {
    let mounted = true;


    const visibility = new MutationObserver(stopWhenHidden);
    visibility.observe(document.documentElement, { attributeFilter: ["class"], attributes: true });
    document.addEventListener("visibilitychange", stopWhenHidden);

    const connect = async () => {
      try {
        const session = await getPlayground(host).connect();
        const listing = await session.list();

        if (mounted) {
          connection = session;
          const { tools: availableTools } = listing;
          tools = availableTools;
          result = JSON.stringify({ serverInfo: session.serverInfo, tools: listing.tools.map((tool) => tool.name) }, null, 2);
        }
      } catch (error_) {
        if (mounted) {error = error_ instanceof Error ? error_.message : String(error_);}
      }
    };

    void connect();

    return () => { mounted = false; pending?.abort(); visibility.disconnect(); document.removeEventListener("visibilitychange", stopWhenHidden); };
  });
</script>

<section class="mcp-playground" aria-label={text.agentDetails}>
  <header><span class="mcp-mark" aria-hidden="true">⌘</span><div><h1>MCP</h1><span class="connection" class:connected={!!connection}>{connection ? text.mcpConnected : text.mcpLoading}</span></div><span class="tool-count" title={text.mcpTools}>{tools.length}</span></header>
  <form onsubmit={run}>
    <label for="mcp-tool">{text.mcpTool}</label>
    <select id="mcp-tool" aria-label={text.mcpTool} bind:value={selected} onchange={chooseTool} disabled={!connection}>{#each tools as tool (tool.name)}<option value={tool.name}>{tool.name}</option>{/each}</select>
    <p class="tool-description">{tools.find((tool) => tool.name === selected)?.description ?? ""}</p>
    <label for="mcp-arguments">{text.mcpArguments}</label>
    <textarea id="mcp-arguments" aria-label={text.mcpArguments} bind:value={args} spellcheck="false" autocapitalize="off" rows="5"></textarea>
    <div class="mcp-actions"><button type="submit" disabled={!connection || running || !enabled}>{running ? text.mcpRunning : text.mcpRun}<span aria-hidden="true">↵</span></button>{#if running}<button type="button" class="stop" onclick={() => pending?.abort()}>{text.agentStop}</button>{/if}</div>
  </form>
  {#if error}<p class="error" role="alert">{error}</p>{/if}
  <div class="result-heading"><h2>{text.mcpResult}</h2>{#if elapsed !== undefined}<span>{elapsed} ms</span>{/if}</div>
  <!-- svelte-ignore a11y_no_noninteractive_tabindex (Focus lets keyboard users scroll while reading the result.) -->
  <pre class="mcp-result" aria-label={text.mcpResult} role="region" aria-live="polite" tabindex="0">{result}</pre>
</section>

<style>
  .mcp-playground { padding: 24px; min-height: 100%; color: var(--text-primary); background: var(--bg-primary); font: 12px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; box-sizing: border-box; }
  header { display: flex; align-items: center; gap: 12px; margin-bottom: 24px; }
  h1 { font-size: 17px; font-weight: 650; margin: 0 0 2px; letter-spacing: -.4px; }
  .mcp-mark { display: grid; place-items: center; width: 38px; height: 38px; border-radius: 11px; font-size: 24px; background: var(--bg-hover); }
  .connection { color: var(--text-secondary); font-size: 10px; }
  .connection::before { content: ""; display: inline-block; width: 5px; height: 5px; border-radius: 50%; margin-right: 5px; background: var(--text-muted); }
  .connection.connected::before { background: #4f9a6e; }
  .tool-count { margin-left: auto; padding: 3px 8px; border-radius: 12px; background: var(--bg-hover); color: var(--text-secondary); font-variant-numeric: tabular-nums; }
  form { display: flex; flex-direction: column; }
  label, h2 { font-size: 10px; text-transform: uppercase; letter-spacing: 1px; font-weight: 600; color: var(--text-secondary); margin: 0 0 6px; }
  select, textarea { width: 100%; box-sizing: border-box; border: 1px solid var(--border); background: var(--bg-hover); border-radius: 7px; padding: 8px 10px; color: inherit; font: 11px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; }
  .tool-description { margin: 8px 0 18px; color: var(--text-secondary); font-size: 11px; line-height: 1.5; }
  textarea { resize: vertical; min-height: 110px; }
  button { display: flex; justify-content: space-between; margin-top: 10px; align-items: center; border: 0; border-radius: 7px; padding: 8px 12px; background: var(--accent); color: white; font: inherit; font-weight: 600; cursor: pointer; }
  button:disabled { opacity: .5; cursor: default; }
  .mcp-actions { display: flex; gap: 6px; }
  .mcp-actions > button[type=submit] { flex: 1; }
  .mcp-actions > .stop { background: var(--bg-hover); color: var(--text-primary); border: 1px solid var(--border); }
  button:focus-visible, select:focus-visible, textarea:focus-visible, pre:focus-visible { outline: var(--focus-outline); outline-offset: 3px; }
  .error { margin: 14px 0 0; font-size: 11px; color: var(--danger); overflow-wrap: anywhere; }
  .result-heading { display: flex; align-items: baseline; justify-content: space-between; margin: 24px 0 6px; color: var(--text-muted); font-size: 10px; }
  .result-heading h2 { margin: 0; }
  pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 11px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--text-secondary); }
</style>
