<!-- A conversation folder as one strip tab: the agent, the title, its state. The count opens its pages;
     while the agent waits, its amber pip opens the question, so nothing covers the page unasked. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { backOut } from "svelte/easing";
  import { fade, scale } from "svelte/transition";
  import MascotGlyph from "../agents/MascotGlyph.svelte";
  import PermissionButtons from "../agents/PermissionButtons.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import StripPopover from "./StripPopover.svelte";
  import { folderActions, tabActions } from "../../lib/bridge/actions";
  import type { BridgeTabFolderSnapshot } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import { getConversationSummary } from "../../stores/conversations.svelte";
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
  const waiting = $derived(!!tab.awaitingInputSince && !active);
  const busy = $derived(tab.terminalState === "busy" || tab.terminalState === "starting");
  const unread = $derived(!!tab.hasUnreadOutput && !active);
  const permission = $derived(active ? undefined : getConversationSummary(tab.id)?.permission);
  const label = $derived(
    [title, waiting ? t("tabItem.terminalAttention") : busy ? t("agents.row.working") : "", unread ? t("tabItem.terminalUnread") : ""]
      .filter(Boolean)
      .join(", "),
  );

  let element: HTMLDivElement | undefined = $state();
  let pagesOpen = $state(false);
  let questionOpen = $state(false);

  function activate(target: TabState): void {
    pagesOpen = false;
    questionOpen = false;
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
  class:waiting
  data-tab-id={tab.id}
  oncontextmenu={showMenu}
>
  <button class="main" role="tab" aria-selected={active} aria-label={label} tabindex={active ? 0 : -1} data-roving onclick={() => activate(tab)}>
    <MascotGlyph />
    <span class="title">{title}</span>
  </button>
  {#if pages.length > 0}
    <button
      class="side-button count"
      tabindex="-1"
      data-roving
      aria-label={t("agents.row.pages", { count: pages.length })}
      aria-expanded={pagesOpen}
      onclick={() => {
        questionOpen = false;
        pagesOpen = !pagesOpen;
      }}
    >{pages.length}</button>
  {/if}
  {#if waiting && permission}
    <button
      class="side-button"
      tabindex="-1"
      data-roving
      aria-label={t("tabItem.terminalAttention")}
      aria-expanded={questionOpen}
      onclick={() => {
        pagesOpen = false;
        questionOpen = !questionOpen;
      }}
    ><span
      class="pip attention"
      aria-hidden="true"
      in:scale={{ start: 0.3, duration: prefersReducedMotion() ? 0 : 360, easing: backOut }}
    ></span></button>
  {:else if busy}
    <span class="state" aria-hidden="true"><span class="spinner" in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}></span></span>
  {:else if unread}
    <span class="state" aria-hidden="true"><span class="pip unread" in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}></span></span>
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

<!-- Closes by itself once answered: the permission leaves the summary. -->
{#if questionOpen && permission && element}
  <StripPopover anchor={element} onclose={() => (questionOpen = false)} label={title}>
    <div class="question">
      <div class="question-head">
        <MascotGlyph />
        <span class="question-name">{title}</span>
      </div>
      <p class="question-title">{permission.title}</p>
      <div class="question-actions">
        <PermissionButtons tabId={tab.id} requestId={permission.requestId} options={permission.options} />
        <button class="open" onclick={() => activate(tab)}>{t("common.open")}</button>
      </div>
    </div>
  </StripPopover>
{/if}

<style>
  /* StripTab's pill, at its resting width. */
  .strip-conversation {
    flex: 0 1 200px;
    min-width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    transition: background-color var(--motion-duration-fast) ease;
  }

  .strip-conversation:hover {
    background: var(--bg-hover);
  }

  .strip-conversation.active {
    background: var(--bg-selected);
    color: var(--text-primary);
    box-shadow: var(--shadow-control);
  }

  .strip-conversation.waiting {
    background: color-mix(in srgb, var(--attention) 14%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--attention) 40%, transparent);
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
    font-size: var(--font-size-sm);
    cursor: default;
  }

  .title {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .side-button,
  .state {
    flex: none;
    min-width: 20px;
    height: 20px;
    margin-right: 4px;
    display: grid;
    place-items: center;
  }

  .side-button {
    padding: 0 4px;
    border: 0;
    border-radius: var(--radius-xs);
    background: transparent;
    color: var(--text-muted);
    font: inherit;
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .side-button:hover,
  .side-button[aria-expanded="true"] {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .pip {
    width: 7px;
    height: 7px;
    border-radius: 50%;
  }

  .pip.attention {
    background: var(--attention);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--attention) 25%, transparent);
  }

  .pip.unread {
    width: 6px;
    height: 6px;
    background: var(--accent);
  }

  /* About 30 s of turns, then a still arc: a turn left running must not keep the display link up. */
  .spinner {
    width: 11px;
    height: 11px;
    box-sizing: border-box;
    border-radius: 50%;
    border: 1.5px solid var(--text-primary-tint-12);
    border-top-color: var(--agents);
    border-right-color: var(--agents);
    animation: strip-conversation-spin 0.9s linear 33 forwards;
  }

  @keyframes strip-conversation-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .spinner {
      animation: none;
    }
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

  .question {
    display: grid;
    gap: 6px;
    padding: 4px 6px 6px;
  }

  .question-head {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .question-name {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
  }

  .question-title {
    margin: 0 0 4px;
    font-size: var(--font-size-sm);
    line-height: 1.35;
    color: var(--text-secondary);
    overflow-wrap: anywhere;
  }

  .question-actions {
    display: flex;
    align-items: flex-start;
    gap: 6px;
  }

  .open {
    flex: none;
    margin-left: auto;
    height: var(--control-height-sm);
    padding: 0 var(--space-10);
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
  }

  .open:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .open:focus-visible,
  .side-button:focus-visible,
  .main:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }
</style>
