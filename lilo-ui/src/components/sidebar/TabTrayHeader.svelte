<!-- The head of the agents or the terminals tray. Open, a quiet label over its rows; folded, a row of
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
    tray: "agent" | "terminal";
    folded: boolean;
    /** The tray's tabs: a terminal's own, an agent's conversation. */
    tabs: TabState[];
    interactive: boolean;
    tabStop: boolean;
    onToggle: (folded: boolean) => void;
  } = $props();

  const label = $derived(t(tray === "agent" ? "tabSection.trayAgents" : "tabSection.trayTerminals"));
  const waiting = $derived(tabs.filter((tab) => !!tab.awaitingInputSince).length);
  const busy = $derived(tabs.filter((tab) => tab.terminalState === "busy" || tab.terminalState === "starting").length);
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

{#snippet glyph(size: number)}
  <svg width={size} height={size} viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    {#if tray === "agent"}
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
  <span class="tray-glyph">{@render glyph(folded ? 16 : 14)}</span>
  <span class="tray-label">{label}</span>
  {#if folded}
    <span class="tray-count">{tabs.length}</span>
    <span class="spacer"></span>
    {#if waiting > 0}
      <span class="tray-status"><span class="dot attention"></span>{t("tabSection.trayNeedsInput", { count: waiting })}</span>
    {:else if busy > 0}
      <span class="tray-status">
        <span class="dot" class:agent={tray === "agent"}></span>
        {t(tray === "agent" ? "tabSection.trayWorking" : "tabSection.trayRunning", { count: busy })}
      </span>
    {:else}
      <!-- Nothing needs you: the icons say what is folded away. -->
      <span class="tray-icons" aria-hidden="true">
        {#each tabs.slice(0, 4) as tab (tab.id)}
          {#if tray === "agent"}
            {#await import("../agents/AgentTile.svelte") then { default: AgentTile }}<AgentTile agentId={tab.agentId ?? ""} />{/await}
          {:else}
            <span class="terminal-mini">
              <svg width="9" height="9" viewBox="0 0 16 16" fill="none"><path d="m3.5 4.5 3.5 3.5-3.5 3.5" /><path d="M8.5 11.5h4" /></svg>
            </span>
          {/if}
        {/each}
      </span>
    {/if}
  {:else}
    <span class="spacer"></span>
    <span class="tray-count reveal">{tabs.length}</span>
  {/if}
  <span class="tray-chevron" class:reveal={!folded} use:tooltip={{ text: toggleLabel }} aria-hidden="true">
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
      <path d="M3.75 2.25 6.5 5 3.75 7.75" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  </span>
</div>

<style>
  /* Open: a label in the row grid, glyph over the icons and text over the titles. */
  .tray-header {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 28px;
    padding: 2px 8px 0;
    box-sizing: border-box;
    border-radius: var(--radius-md);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    color: var(--text-secondary);
    cursor: default;
  }

  .tray-header:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* Folded: a row like the tabs it holds. */
  .tray-header.folded {
    height: 32px;
    padding-top: 0;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-regular);
    color: var(--text-primary);
    transition: background var(--transition-fast);
  }

  .tray-header.folded:hover {
    background: var(--bg-hover);
  }

  .tray-glyph {
    flex: none;
    display: grid;
    place-items: center;
    width: 16px;
    height: 16px;
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
    font-weight: var(--font-weight-medium);
    font-variant-numeric: tabular-nums;
    color: var(--text-muted);
  }

  .folded .tray-count {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-regular);
  }

  .spacer {
    flex: 1;
  }

  .tray-status {
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--font-size-sm);
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
    flex: none;
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
    border-radius: var(--radius-sm);
    color: var(--text-muted);
    transform: rotate(90deg);
    transition:
      opacity var(--transition-fast),
      transform 200ms var(--motion-ease-spring);
  }

  .folded .tray-chevron {
    transform: none;
  }

  /* Open, the count and the chevron wait for the pointer: the label alone heads the tray. */
  .reveal {
    opacity: 0;
    transition: opacity var(--transition-fast);
  }

  .tray-header:hover .reveal,
  .tray-header:focus-visible .reveal {
    opacity: 1;
  }

  .tray-header:not(.folded):hover .tray-chevron {
    background: var(--text-primary-tint-12);
    color: var(--text-primary);
  }

  @media (prefers-reduced-motion: reduce) {
    .tray-chevron {
      transition: none;
    }
  }
</style>
