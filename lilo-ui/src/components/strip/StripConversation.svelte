<!-- A conversation folder as one strip tab, with the grammar of the sidebar's row: the agent's icon with
     its state as a badge, the title, the diff. Hovered, the diff gives way to the button for its pages. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { backOut } from "svelte/easing";
  import { fade, scale } from "svelte/transition";
  import AgentTile from "../agents/AgentTile.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import StripPopover from "./StripPopover.svelte";
  import { folderActions, tabActions } from "../../lib/bridge/actions";
  import type { BridgeTabFolderSnapshot } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import { closeHistoryShell, closeSettingsShell } from "../../stores/panels.svelte";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import { tabDisplayTitle, type TabState } from "../../stores/tabs.svelte";

  let {
    folder,
    tab,
    pages,
    activeTabId,
  }: {
    folder: BridgeTabFolderSnapshot;
    /** The conversation's own tab. */
    tab: TabState;
    /** The tabs the agent opened. */
    pages: TabState[];
    activeTabId: string;
  } = $props();

  const active = $derived(tab.id === activeTabId);
  const title = $derived(tabDisplayTitle(tab.title ?? "") || t("agents.row.untitled"));
  const waiting = $derived(!!tab.awaitingInputSince);
  const busy = $derived(tab.terminalState === "busy" || tab.terminalState === "starting");
  const unread = $derived(!!tab.hasUnreadOutput && !active);
  const added = $derived(tab.diffAdded ?? 0);
  const removed = $derived(tab.diffRemoved ?? 0);
  const label = $derived(
    [
      title,
      waiting ? t("tabItem.terminalAttention") : busy ? t("agents.row.working") : "",
      unread ? t("tabItem.terminalUnread") : "",
      added || removed ? t("agents.row.changes", { added, removed }) : "",
    ]
      .filter(Boolean)
      .join(", "),
  );

  let element: HTMLDivElement | undefined = $state();
  let pagesOpen = $state(false);

  function activate(target: TabState): void {
    pagesOpen = false;
    closeSettingsShell();
    closeHistoryShell();
    optimisticallyActivateTab(target.id);
    tabActions.switchTo(target.id);
  }

  function showMenu(event: MouseEvent): void {
    event.preventDefault();
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    folderActions.showContextMenu(folder.id, rect.x, rect.y, rect.width, rect.height);
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  bind:this={element}
  class="strip-conversation"
  class:active
  class:has-pages={pages.length > 0}
  data-tab-id={tab.id}
  oncontextmenu={showMenu}
>
  <button class="main" role="tab" aria-selected={active} aria-label={label} tabindex={active ? 0 : -1} data-roving onclick={() => activate(tab)}>
    <span class="icon">
      <AgentTile agentId={tab.agentId ?? ""} />
      {#if waiting}
        <span
          class="badge attention"
          aria-hidden="true"
          in:scale={{ start: 0.3, duration: prefersReducedMotion() ? 0 : 360, easing: backOut }}
          out:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}
        ></span>
      {:else if busy}
        <span class="badge spinner" aria-hidden="true" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
      {:else if unread}
        <span class="badge unread" aria-hidden="true" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
      {/if}
    </span>
    <span class="title">{title}</span>
    {#if added || removed}
      <span class="diff" aria-hidden="true">
        {#if added}<span class="added">+{added}</span>{/if}
        {#if removed}<span class="removed">-{removed}</span>{/if}
      </span>
    {/if}
  </button>
  {#if pages.length > 0}
    <button
      class="pages"
      tabindex="-1"
      data-roving
      aria-label={t("agents.row.pages", { count: pages.length })}
      aria-expanded={pagesOpen}
      onclick={() => (pagesOpen = !pagesOpen)}
    >
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
        <path d="M2.25 3.75 5 6.5l2.75-2.75" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
  {/if}
</div>

{#if pagesOpen && element}
  <StripPopover anchor={element} onclose={() => (pagesOpen = false)} label={title}>
    {#each pages as page (page.id)}
      <button class="popover-row" class:active={page.id === activeTabId} onclick={() => activate(page)}>
        <SiteFavicon src={page.faviconDataURL} title={page.title} url={page.url} size={16} radius={4} />
        <span class="row-title">{tabDisplayTitle(page.title) || page.url}</span>
      </button>
    {/each}
  </StripPopover>
{/if}

<style>
  /* StripTab's pill, at its resting width. */
  .strip-conversation {
    position: relative;
    flex: 0 1 200px;
    min-width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    border-radius: var(--radius-md);
    container-type: inline-size;
    color: var(--text-secondary);
    transition: background-color var(--motion-duration-fast) ease;
  }

  .strip-conversation:hover {
    background: var(--bg-hover);
  }

  .strip-conversation.active {
    background: var(--sidebar-sel);
    color: var(--text-primary);
    box-shadow: inset 0 0 0 0.5px var(--sidebar-sel-ring);
  }

  .main {
    flex: 1;
    min-width: 0;
    height: 100%;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 8px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    font-size: var(--font-size-md);
    cursor: default;
  }

  .icon {
    position: relative;
    flex: none;
    display: grid;
  }

  /* On the icon's corner, ringed in the bar's colour so it reads on any icon. */
  .badge {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    box-shadow: 0 0 0 2px var(--sidebar-bg);
  }

  .badge.attention {
    background: var(--attention);
  }

  .badge.unread {
    background: var(--accent);
  }

  /* About 30 s of turns, then a still arc: a turn left running must not keep the display link up. */
  .badge.spinner {
    width: 8px;
    height: 8px;
    right: -4px;
    bottom: -4px;
    box-sizing: border-box;
    border: 1.5px solid var(--text-primary-tint-12);
    border-top-color: var(--agents);
    border-right-color: var(--agents);
    background: var(--sidebar-bg);
    animation: strip-conversation-spin 0.9s linear 33 forwards;
  }

  @keyframes strip-conversation-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .badge.spinner {
      animation: none;
    }
  }

  .title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    text-align: left;
  }

  .diff {
    flex: none;
    display: inline-flex;
    gap: 4px;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    font-variant-numeric: tabular-nums;
  }

  .added {
    color: color-mix(in srgb, var(--diff-added) 70%, var(--text-primary));
  }

  .removed {
    color: color-mix(in srgb, var(--diff-removed) 70%, var(--text-primary));
  }

  /* The accessory slot: the diff at rest, the pages button while hovered or open. */
  .pages {
    display: none;
    flex: none;
    width: 20px;
    height: 20px;
    margin-right: 4px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-xs);
    background: transparent;
    color: var(--text-muted);
    place-items: center;
  }

  .strip-conversation:hover .pages,
  .pages[aria-expanded="true"],
  .pages:focus-visible {
    display: grid;
  }

  .strip-conversation.has-pages:hover .diff {
    display: none;
  }

  .pages:hover,
  .pages[aria-expanded="true"] {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  /* StripFolder's popover rows. */
  .popover-row {
    width: 100%;
    height: 32px;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 8px;
    border: 0;
    border-radius: calc(var(--float-radius-popover) - 6px);
    background: transparent;
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
  }

  .popover-row:hover,
  .popover-row:focus-visible,
  .popover-row.active {
    background: var(--bg-hover);
  }

  .row-title {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .pages:focus-visible,
  .main:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* Folded to its icon, as a tab pill is; the state badge stays on the icon. */
  @container (max-width: 47px) {
    .title,
    .diff,
    .pages {
      display: none;
    }

    .main {
      justify-content: center;
      padding: 0;
    }
  }
</style>
