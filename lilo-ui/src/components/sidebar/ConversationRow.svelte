<!-- A conversation folder drawn as one row: the agent, the title, its pages behind the chevron, its state.
     The question the agent waits on opens under the row while the conversation is off screen. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { backOut } from "svelte/easing";
  import { fade, scale } from "svelte/transition";
  import MascotGlyph from "../agents/MascotGlyph.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import { getConversationSummary } from "../../stores/conversations.svelte";
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
  const waiting = $derived(!!tab.awaitingInputSince && !isActive);
  const busy = $derived(tab.terminalState === "busy" || tab.terminalState === "starting");
  const unread = $derived(!!tab.hasUnreadOutput && !isActive);
  const failed = $derived(tab.terminalState === "failed");
  const added = $derived(tab.diffAdded ?? 0);
  const removed = $derived(tab.diffRemoved ?? 0);
  const permission = $derived(isActive ? undefined : getConversationSummary(tab.id)?.permission);
  // The last question stays drawn while its card folds away.
  let lastPermission: typeof permission;
  const question = $derived.by(() => {
    if (permission) lastPermission = permission;
    return lastPermission;
  });
  const expanded = $derived(pageCount > 0 && !folder.isCollapsed);
  const rowLabel = $derived(
    [
      title,
      waiting ? t("tabItem.terminalAttention") : busy ? t("agents.row.working") : failed ? t("agents.row.failed") : "",
      unread ? t("tabItem.terminalUnread") : "",
      added || removed ? t("agents.row.changes", { added, removed }) : "",
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
  class:needs-attention={waiting}
  class:asking={!!permission}
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
  <MascotGlyph />
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
      class="pages"
      tabindex="-1"
      aria-label={t(expanded ? "agents.row.hidePages" : "agents.row.showPages")}
      aria-expanded={expanded}
      onclick={(event) => {
        event.stopPropagation();
        onCollapse(expanded);
      }}
    >
      <span class="count">{pageCount}</span>
      <svg class="chevron" class:open={expanded} width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
        <path d="M3.75 2.25 6.5 5 3.75 7.75" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
  {/if}
  {#if interactive}
    <button
      type="button"
      class="close"
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
  <!-- States cross-fade in one cell; the amber pip arrives with a single soft pulse, then rests. -->
  <span class="state" aria-hidden="true">
    {#if waiting}
      <span
        class="pip attention"
        in:scale={{ start: 0.3, duration: prefersReducedMotion() ? 0 : 360, easing: backOut }}
        out:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}
      ></span>
    {:else if busy}
      <span class="spinner" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
    {:else if failed}
      <span class="pip failed" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
    {:else if unread}
      <span class="pip unread" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
    {/if}
  </span>
</div>

<!-- Always present, so a new question unfolds from nothing and an answered one folds away. -->
<div class="question-shell" class:open={!!permission} inert={!permission}>
  <div class="question-clip">
    {#if question}
      <div class="question" role="group" aria-label={question.title}>
        <p class="question-title">{question.title}</p>
        {#await import("../agents/PermissionButtons.svelte") then { default: PermissionButtons }}
          <PermissionButtons tabId={tab.id} requestId={question.requestId} options={question.options} />
        {/await}
      </div>
    {/if}
  </div>
</div>

<style>
  /* TabItem's row geometry, so a conversation lines up with the tabs around it. */
  .conversation-row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-width: 0;
    height: 28px;
    padding: 6px;
    box-sizing: border-box;
    border-radius: var(--radius-md);
    overflow: hidden;
    transition:
      background var(--transition-fast),
      box-shadow var(--transition-fast);
  }

  .conversation-row.interactive {
    cursor: pointer;
  }

  .conversation-row:hover {
    background: color-mix(in srgb, var(--bg-selected) 20%, transparent);
  }

  .conversation-row:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .conversation-row.active {
    background: color-mix(in srgb, var(--accent) 18%, var(--bg-selected));
  }

  .conversation-row.needs-attention {
    background: color-mix(in srgb, var(--attention) 14%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--attention) 40%, transparent);
  }

  .conversation-row.asking {
    border-bottom-left-radius: 0;
    border-bottom-right-radius: 0;
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

  .pages {
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: 2px;
    height: 20px;
    padding: 0 4px;
    margin: 0 -4px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    font-family: inherit;
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
    cursor: pointer;
  }

  .pages:hover {
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
  }

  .chevron {
    transition: transform var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .chevron.open {
    transform: rotate(90deg);
  }

  /* One column for every state, so the title never shifts as the agent works. */
  /* The close button takes the state's place while the row is hovered: nothing reflows. */
  .close {
    display: none;
    flex: none;
    width: 18px;
    height: 18px;
    margin-right: -2px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    place-items: center;
    cursor: pointer;
  }

  .close:hover {
    background: var(--text-primary-tint-12);
    color: var(--text-primary);
  }

  .conversation-row:hover .close,
  .conversation-row:focus-visible .close {
    display: grid;
    animation: conversation-close-in var(--motion-duration-fast) var(--motion-ease-standard);
  }

  @keyframes conversation-close-in {
    from {
      opacity: 0;
      transform: scale(0.85);
    }
  }

  .conversation-row:hover .state,
  .conversation-row:focus-visible .state {
    display: none;
  }

  .state {
    flex: none;
    width: 14px;
    height: 14px;
    display: grid;
    place-items: center;
  }

  .state > * {
    grid-area: 1 / 1;
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

  .pip.failed {
    background: var(--danger);
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
    animation: conversation-spin 0.9s linear 33 forwards;
  }

  @keyframes conversation-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .spinner {
      animation: none;
    }
  }

  .question-shell {
    display: grid;
    grid-template-rows: 0fr;
    opacity: 0;
    transform: translateY(-3px);
    transition:
      grid-template-rows 150ms var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease,
      transform 150ms var(--motion-ease-spring);
  }

  .question-shell.open {
    grid-template-rows: 1fr;
    opacity: 1;
    transform: none;
    transition-duration: var(--motion-duration-overlay), var(--motion-duration-normal), var(--motion-duration-overlay);
  }

  .question-clip {
    min-height: 0;
    overflow: hidden;
  }

  .question {
    padding: 8px 10px 10px;
    border-radius: 0 0 var(--radius-md) var(--radius-md);
    background: color-mix(in srgb, var(--attention) 8%, transparent);
    box-shadow:
      inset 1px 0 0 color-mix(in srgb, var(--attention) 40%, transparent),
      inset -1px 0 0 color-mix(in srgb, var(--attention) 40%, transparent),
      inset 0 -1px 0 color-mix(in srgb, var(--attention) 40%, transparent);
  }

  .question-title {
    margin: 0 0 8px;
    font-size: var(--font-size-sm);
    line-height: 1.35;
    color: var(--text-primary);
    overflow-wrap: anywhere;
  }
</style>
