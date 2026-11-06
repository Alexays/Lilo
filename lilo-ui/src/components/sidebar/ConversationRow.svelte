<!-- A conversation folder drawn as one row: the agent's icon with its state as a badge, the title, the
     diff; its pages are the nested rows the disclosure shows. A question it asks lives in the conversation
     and the Agents popover: the row keeps only the orange dot. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { backOut } from "svelte/easing";
  import { fade, scale } from "svelte/transition";
  import AgentTile from "../agents/AgentTile.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import type { FolderState } from "../../stores/folders.svelte";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import { tabDisplayTitle, type TabState } from "../../stores/tabs.svelte";

  let {
    folder,
    tab,
    pageCount,
    isActive,
    interactive = true,
    level = 1,
    tabStop = true,
    onCollapse,
    onContextMenu,
  }: {
    folder: FolderState;
    /** The conversation's own tab, the folder's first child. */
    tab: TabState;
    pageCount: number;
    isActive: boolean;
    interactive?: boolean;
    level?: number;
    tabStop?: boolean;
    onCollapse: (collapsed: boolean) => void;
    onContextMenu: (rect: DOMRect) => void;
  } = $props();

  const title = $derived(tabDisplayTitle(tab.title ?? "") || t("agents.row.untitled"));
  const waiting = $derived(!!tab.awaitingInputSince);
  const busy = $derived(tab.terminalState === "busy" || tab.terminalState === "starting");
  const unread = $derived(!!tab.hasUnreadOutput && !isActive);
  const failed = $derived(tab.terminalState === "failed");
  const added = $derived(tab.diffAdded ?? 0);
  const removed = $derived(tab.diffRemoved ?? 0);
  const expanded = $derived(pageCount > 0 && !folder.isCollapsed);
  const rowLabel = $derived(
    [
      title,
      waiting ? t("tabItem.terminalAttention") : busy ? t("agents.row.working") : failed ? t("agents.row.failed") : "",
      unread ? t("tabItem.terminalUnread") : "",
      added ? t("agents.row.linesAdded", { count: added }) : "",
      removed ? t("agents.row.linesRemoved", { count: removed }) : "",
      pageCount ? t("agents.row.pages", { count: pageCount }) : "",
    ].filter(Boolean).join(", "),
  );

  function activate(): void {
    if (!interactive) return;
    optimisticallyActivateTab(tab.id);
    tabActions.switchTo(tab.id);
  }

  function handleKeydown(event: KeyboardEvent): void {
    if (!interactive || event.target !== event.currentTarget) return;
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      activate();
    } else if (pageCount > 0 && (event.key === "ArrowLeft" ? expanded : event.key === "ArrowRight" && !expanded)) {
      // Left on a closed row is left to the list, which moves up to the parent folder.
      event.preventDefault();
      onCollapse(event.key === "ArrowLeft");
    }
  }
</script>

<!-- `.folder-row`: the list's arrow keys treat it as a folder header. -->
<div
  class="folder-row conversation-row"
  class:active={isActive}
  class:interactive
  role="treeitem"
  aria-level={level}
  aria-selected={isActive}
  aria-expanded={pageCount > 0 ? expanded : undefined}
  aria-label={rowLabel}
  tabindex={interactive && tabStop ? 0 : -1}
  onclick={activate}
  oncontextmenu={(event) => {
    event.preventDefault();
    event.stopPropagation();
    onContextMenu((event.currentTarget as HTMLElement).getBoundingClientRect());
  }}
  onkeydown={handleKeydown}
>
  <!-- The state is a badge on the icon, never in its place; the orange dot arrives with one soft pop. -->
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
    {:else if failed}
      <span class="badge failed" aria-hidden="true" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
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
  {#if pageCount > 0}
    <button
      type="button"
      class="hover-button disclosure"
      tabindex="-1"
      aria-label={t(expanded ? "agents.row.hidePages" : "agents.row.showPages")}
      aria-expanded={expanded}
      onclick={(event) => {
        event.stopPropagation();
        onCollapse(expanded);
      }}
    >
      <svg class="chevron" class:open={expanded} width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
        <path d="M3.75 2.25 6.5 5 3.75 7.75" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
  {/if}
  {#if interactive}
    <button
      type="button"
      class="hover-button"
      aria-label={t("tabItem.closeTab")}
      tabindex="-1"
      onclick={(event) => {
        event.stopPropagation();
        tabActions.close(tab.id);
      }}
    >
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
        <path d="M2.5 2.5l5 5M7.5 2.5l-5 5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
      </svg>
    </button>
  {/if}
</div>

<style>
  /* TabItem's row geometry, so a conversation lines up with the tabs around it. */
  .conversation-row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-width: 0;
    height: 32px;
    padding: 0 8px;
    box-sizing: border-box;
    border-radius: var(--radius-md);
    overflow: hidden;
    transition: background var(--transition-fast);
  }

  .conversation-row.interactive {
    cursor: pointer;
  }

  .conversation-row:hover {
    background: var(--bg-hover);
  }

  .conversation-row:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .conversation-row.active {
    background: var(--sidebar-sel);
    box-shadow: inset 0 0 0 0.5px var(--sidebar-sel-ring);
  }

  .icon {
    position: relative;
    flex: none;
    display: grid;
    width: 16px;
    height: 16px;
  }

  /* On the icon's bottom-right corner, ringed in the sidebar colour so it reads on any icon. */
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

  .badge.failed {
    background: var(--danger);
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
    animation: conversation-spin 0.9s linear 33 forwards;
  }

  @keyframes conversation-spin {
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
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-size: var(--font-size-md);
    line-height: 1.3;
    color: var(--text-primary);
  }

  .diff {
    flex: none;
    display: inline-flex;
    gap: 4px;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    font-variant-numeric: tabular-nums;
  }

  /* Pulled toward the text colour so both read on any Space tint, light or dark. */
  .added {
    color: color-mix(in srgb, var(--diff-added) 70%, var(--text-primary));
  }

  .removed {
    color: color-mix(in srgb, var(--diff-removed) 70%, var(--text-primary));
  }

  /* The accessory slot: the diff at rest, the disclosure and close while the row is hovered. */
  .hover-button {
    display: none;
    flex: none;
    width: 20px;
    height: 20px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    place-items: center;
    cursor: pointer;
  }

  .hover-button:last-child {
    margin-right: -2px;
  }

  .hover-button:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .conversation-row:hover .hover-button,
  .conversation-row:focus-visible .hover-button {
    display: grid;
    animation: conversation-button-in var(--motion-duration-fast) var(--motion-ease-standard);
  }

  .conversation-row:hover .diff,
  .conversation-row:focus-visible .diff {
    display: none;
  }

  @keyframes conversation-button-in {
    from {
      opacity: 0;
    }
  }

  .chevron {
    transition: transform var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .chevron.open {
    transform: rotate(90deg);
  }
</style>
