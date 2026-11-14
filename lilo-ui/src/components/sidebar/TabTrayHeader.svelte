<!-- The head of a project's tray, or of the agents or the terminals tray. Open, a quiet label over its rows; folded, a row of
     its own that still says what needs you, or else shows what it holds. -->
<script lang="ts">
  import { tooltip } from "../../lib/tooltip";
  import { t } from "../../lib/i18n/state.svelte";
  import type { TabState } from "../../stores/tabs.svelte";

  let {
    tray,
    folded,
    tabs,
    interactive,
    tabStop,
    onToggle,
  }: {
    /** "agent", "terminal", or `project:<root>`. */
    tray: string;
    folded: boolean;
    /** The tray's tabs: a terminal's own, an agent's conversation. */
    tabs: TabState[];
    interactive: boolean;
    tabStop: boolean;
    onToggle: (folded: boolean) => void;
  } = $props();

  const project = $derived(tray.startsWith("project:") ? tray.slice("project:".length) : null);
  const label = $derived(
    project ? project.slice(project.lastIndexOf("/") + 1) : t(tray === "agent" ? "tabSection.trayAgents" : "tabSection.trayTerminals"),
  );
  const waiting = $derived(tabs.filter((tab) => !!tab.awaitingInputSince).length);
  const busy = $derived(tabs.filter((tab) => tab.terminalState === "busy" || tab.terminalState === "starting"));
  const busyAgents = $derived(busy.filter((tab) => tab.kind === "agent").length);
  const toggleLabel = $derived(t(folded ? "tabSection.trayShow" : "tabSection.trayHide", { name: label }));

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Enter" || event.key === " ") onToggle(!folded);
    else if (event.key === "ArrowRight" && folded) onToggle(false);
    else if (event.key === "ArrowLeft" && !folded) onToggle(true);
    else return;
    event.preventDefault();
    event.stopPropagation();
  }
</script>

{#snippet glyph()}
  <svg width="16" height="16" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    {#if project}
      <path d="M2.8 6.2c0-1 .8-1.8 1.8-1.8h3.2l1.8 1.9h5.8c1 0 1.8.8 1.8 1.8v6.3c0 1-.8 1.8-1.8 1.8H4.6c-1 0-1.8-.8-1.8-1.8z" />
    {:else if tray === "agent"}
      <circle cx="10" cy="10" r="6.6" />
      <ellipse cx="7.6" cy="9.4" rx="1.05" ry="1.4" fill="currentColor" stroke="none" />
      <ellipse cx="12.4" cy="9.4" rx="1.05" ry="1.4" fill="currentColor" stroke="none" />
    {:else}
      <rect x="2.8" y="3.8" width="14.4" height="12.4" rx="2.6" />
      <path d="m6.2 8 2.4 2-2.4 2" />
      <path d="M10.4 12.4h3.4" />
    {/if}
  </svg>
{/snippet}

<!-- One layout open or folded, so nothing moves or resizes as it toggles: only the chevron turns
     and, folded, a summary of what it holds fades in. -->
<div
  class="tray-header"
  class:folded
  role="treeitem"
  aria-level={1}
  aria-selected={false}
  aria-expanded={!folded}
  aria-label={label}
  tabindex={tabStop ? 0 : -1}
  onclick={() => interactive && onToggle(!folded)}
  onkeydown={handleKeydown}
>
  <span class="tray-glyph">{@render glyph()}</span>
  <span class="tray-label" use:tooltip={{ text: project?.replace(/^\/Users\/[^/]+/, "~") ?? "" }}>{label}</span>
  <span class="tray-count">{tabs.length}</span>
  <span class="spacer"></span>
  {#if folded}
    <span class="tray-summary">
      {#if waiting > 0}
        <span class="tray-status"><span class="dot attention"></span>{t("tabSection.trayNeedsInput", { count: waiting })}</span>
      {:else if busyAgents > 0}
        <span class="tray-status"><span class="dot agent"></span>{t("tabSection.trayWorking", { count: busyAgents })}</span>
      {:else if busy.length > 0}
        <span class="tray-status"><span class="dot"></span>{t("tabSection.trayRunning", { count: busy.length })}</span>
      {:else}
        <!-- Nothing needs you: the icons say what is folded away. -->
        <span class="tray-icons" aria-hidden="true">
          {#each tabs.slice(0, 4) as tab (tab.id)}
            {#if tab.kind === "agent"}
              {#await import("../agents/AgentTile.svelte") then { default: AgentTile }}<AgentTile agentId={tab.agentId ?? ""} />{/await}
            {:else}
              <span class="terminal-mini">
                <svg width="9" height="9" viewBox="0 0 16 16" fill="none"><path d="m3.5 4.5 3.5 3.5-3.5 3.5" /><path d="M8.5 11.5h4" /></svg>
              </span>
            {/if}
          {/each}
        </span>
      {/if}
    </span>
  {/if}
  <span class="tray-chevron" use:tooltip={{ text: toggleLabel }} aria-hidden="true">
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
      <path d="M3.75 2.25 6.5 5 3.75 7.75" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  </span>
</div>

<style>
  .tray-header {
    display: flex;
    align-items: center;
    gap: 8px;
    height: var(--interface-row-height);
    padding: 0 8px;
    box-sizing: border-box;
    border-radius: var(--radius-md);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    color: var(--text-secondary);
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .tray-header:hover {
    background: var(--bg-hover);
  }

  .tray-header:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .tray-header.folded {
    color: var(--text-primary);
  }

  .tray-glyph {
    flex: none;
    display: grid;
    place-items: center;
    width: var(--interface-icon-size);
    height: var(--interface-icon-size);
    opacity: 0.85;
  }

  .tray-label {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .tray-count {
    flex: none;
    font-weight: var(--font-weight-regular);
    font-variant-numeric: tabular-nums;
    color: var(--text-muted);
  }

  .spacer {
    flex: 1;
  }

  .tray-summary {
    flex: none;
    display: flex;
    animation: tray-summary-in var(--motion-duration-normal) ease both;
  }

  @keyframes tray-summary-in {
    from {
      opacity: 0;
    }
  }

  .tray-status {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-regular);
    color: var(--text-secondary);
    white-space: nowrap;
  }

  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--accent) 55%, white);
  }

  .dot.agent {
    background: var(--agents);
  }

  .dot.attention {
    background: var(--attention);
  }

  .tray-icons {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .terminal-mini {
    display: grid;
    place-items: center;
    width: 14px;
    height: 14px;
    border-radius: var(--radius-xs);
    background: var(--terminal-tile-bg);
    box-shadow: inset 0 0 0 1px var(--terminal-tile-border);
  }

  .terminal-mini svg {
    stroke: var(--terminal-tile-accent);
    stroke-width: 1.8;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .tray-chevron {
    flex: none;
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    margin-right: -2px;
    color: var(--text-muted);
    transform: rotate(90deg);
    transition: transform var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .folded .tray-chevron {
    transform: none;
  }

  @media (prefers-reduced-motion: reduce) {
    .tray-chevron {
      transition: none;
    }
  }
</style>
