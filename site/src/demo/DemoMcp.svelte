<script lang="ts">
  import { onMount, untrack } from "svelte";
  import type { AgentState } from "./agent.ts";
  import { getSetting } from "../../../lilo-ui/src/stores/settings.svelte";
  import type { DemoHost } from "./host.ts";
  import { getPlayground } from "./playground.ts";
  import { demoCopy } from "./world.ts";
  import type { DemoLocale } from "./world.ts";
  import DemoTools from "./DemoTools.svelte";

  interface Props {
    host: DemoHost;
    locale: DemoLocale;
  }

  let { host, locale }: Props = $props();
  const text = $derived(demoCopy(locale));
  const playground = untrack(() => getPlayground(host));
  const {agent} = playground;
  let session = $state.raw<AgentState>(untrack(() => agent.snapshot()));
  let ready = $state(false);
  let details = $state(false);
  const enabled = $derived(getSetting("agentControlEnabled", "true") === "true");

  const connectionLabel = $derived.by(() => {
    if (!enabled) { return text.agentDisabled; }

    return ready ? text.agentReady : text.mcpLoading;
  });

  $effect(() => { if (!enabled) { agent.stop(); } });

  const active = $derived(session.status === "running" || session.status === "waiting");
  const finalMessage = $derived({ denied: text.agentDenied, done: text.agentComplete, error: text.agentError, idle: "", running: "", stopped: text.agentStopped, waiting: "" }[session.status]);

  onMount(() => {
    let mounted = true;
    const unsubscribe = agent.subscribe(() => { session = agent.snapshot(); });

    const connect = async () => {
      try {
        await playground.connect();

        if (mounted) { ready = true; }
      } catch {
        if (mounted) { session = { status: "error", steps: [] }; }
      }
    };

    void connect();

    const stopWhenHidden = () => {
      if (document.hidden || document.documentElement.classList.contains("reduced-power")) { agent.stop(); }
    };

    const visibility = new MutationObserver(stopWhenHidden);
    visibility.observe(document.documentElement, { attributeFilter: ["class"], attributes: true });
    document.addEventListener("visibilitychange", stopWhenHidden);

    return () => {
      mounted = false;
      agent.stop();
      unsubscribe();
      visibility.disconnect();
      document.removeEventListener("visibilitychange", stopWhenHidden);
    };
  });
</script>

<section class="agent-session" aria-label="Codex" data-agent-status={session.status}>
  <header><img class="codex-mark" src={host.assets?.images.codex} alt="" width="32" height="32" /><div><h1>Codex</h1><span class="connection">{connectionLabel}</span></div><span class="demo-label">{text.agentDemo}</span></header>
  <div class="user-message"><span class="speaker">{text.agentYou}</span><p>{text.agentTask}</p></div>
  {#if session.status !== "idle"}
    <div class="assistant-message"><span class="speaker">Codex</span><p>{text.agentIntro}</p></div>
    <ol class="agent-steps" aria-label={text.mcpRunning}>{#each session.steps as step, index (index)}
      <li class:working={step.status === "running"} class:complete={step.status === "done"}><span class="step-icon" aria-hidden="true">{step.status === "done" ? "✓" : step.status === "stopped" ? "■" : "↳"}</span><div><span>{step.label}</span><code>{step.tool}</code></div></li>
    {/each}</ol>
  {/if}
  <div class="session-state" role="status" aria-live="polite">{session.status === "waiting" ? text.agentPermission : finalMessage}</div>
  <div class="session-actions">{#if active}<button class="stop" type="button" onclick={() => agent.stop()}><span aria-hidden="true">■</span>{text.agentStop}</button>{:else}<button class="run" type="button" disabled={!ready || !enabled} onclick={() => { details = false; void agent.start(); }}>{session.status === "idle" ? text.agentRun : text.agentAgain}</button>{/if}</div>
  <details bind:open={details} inert={active}><summary>{text.agentDetails}<span aria-hidden="true">⌘</span></summary>{#if details}<DemoTools {host} {locale} />{/if}</details>
</section>

<style>
  .agent-session { padding: 22px; min-height: 100%; box-sizing: border-box; color: var(--text-primary); background: var(--bg-primary); font: 12px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  header { display: flex; align-items: center; gap: 10px; margin-bottom: 26px; }
  .codex-mark { display: block; flex: none; width: 32px; height: 32px; object-fit: contain; }
  h1 { margin: 0; font-size: 14px; line-height: 1.5; letter-spacing: -.2px; }
  .connection { display: block; color: var(--text-muted); font-size: 9px; }
  .connection::before { content: ""; display: inline-block; margin-right: 4px; width: 4px; height: 4px; border-radius: 50%; background: #73916e; }
  .demo-label { margin-left: auto; max-width: 94px; color: var(--text-muted); text-align: right; font-size: 9px; line-height: 1.4; }
  .speaker { display: block; margin-bottom: 5px; color: var(--text-secondary); font-size: 10px; font-weight: 600; }
  p { margin: 0; }
  .user-message { padding: 12px 14px; border-radius: 10px; background: var(--bg-hover); }
  .assistant-message { margin: 24px 0 18px; }
  .agent-steps { list-style: none; margin: 0; padding: 0; }
  .agent-steps li { display: flex; align-items: flex-start; gap: 9px; padding: 6px 0; color: var(--text-muted); font-size: 11px; }
  .step-icon { width: 12px; flex: none; text-align: center; font-size: 12px; }
  .agent-steps li.complete .step-icon { color: #73916e; }
  .agent-steps li.working { color: var(--text-primary); }
  code { display: block; margin-top: 1px; color: var(--text-muted); font: 9px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
  .session-state { margin-top: 16px; font-size: 11px; }
  .session-state:empty { display: none; }
  .session-actions { position: sticky; bottom: 0; z-index: 1; display: flex; margin: 20px 0 24px; padding: 10px 0; background: var(--bg-primary); }
  button { display: inline-flex; gap: 20px; align-items: center; border: 1px solid var(--border); border-radius: 7px; padding: 8px 11px; background: var(--bg-hover); color: inherit; font: inherit; font-size: 11px; font-weight: 600; cursor: pointer; }
  .run { background: var(--text-primary); color: var(--bg-primary); }
  button:disabled { opacity: .4; cursor: default; }
  button:focus-visible, summary:focus-visible { outline: var(--focus-outline); outline-offset: 3px; }
  .stop { gap: 8px; }
  .stop > span { font-size: 8px; }
  details { border-top: 1px solid var(--border); margin-top: 20px; padding-top: 12px; }
  details[inert] { opacity: .5; }
  summary { display: flex; justify-content: space-between; color: var(--text-muted); cursor: pointer; font-size: 10px; list-style: none; }
  summary::-webkit-details-marker { display: none; }
</style>
