<!-- The conversations of every Space, what waits on you first. Answering happens in place; a row takes
     you to its conversation. Mounted on the body, so it may run past a narrow sidebar over the page. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import MascotGlyph from "./MascotGlyph.svelte";
  import PermissionButtons from "./PermissionButtons.svelte";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { terminalActions } from "../../lib/bridge/actions";
  import type { BridgeConversationSummary } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { openAskBar } from "../../stores/conversations.svelte";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";

  let { anchor, summaries, onclose }: { anchor: HTMLElement; summaries: BridgeConversationSummary[]; onclose: () => void } = $props();

  const sections = $derived.by(() => {
    const needs: BridgeConversationSummary[] = [];
    const running: BridgeConversationSummary[] = [];
    const done: BridgeConversationSummary[] = [];
    for (const summary of summaries) {
      if (summary.permission) needs.push(summary);
      else if (summary.state === "busy" || summary.state === "starting") running.push(summary);
      else if (summary.unread || summary.state === "failed" || summary.title) done.push(summary);
    }
    return [
      { key: "needs", label: t("agents.badge.needsYou"), items: needs, start: 0 },
      { key: "running", label: t("agents.badge.running"), items: running, start: needs.length },
      { key: "done", label: t("agents.badge.done"), items: done, start: needs.length + running.length },
    ].filter((section) => section.items.length > 0);
  });
  const activeSpaceId = $derived(getActiveSpaceId());
  const askKeys = $derived(shortcutKeys("agents.ask"));

  const WIDTH = 320;
  const MARGIN = 8;
  // Right-aligned with the pill, toward the page whichever edge the pill sits on.
  const position = $derived.by(() => {
    const rect = anchor.getBoundingClientRect();
    const below = rect.top < window.innerHeight / 2;
    return {
      below,
      left: Math.min(Math.max(MARGIN, rect.right + 6 - WIDTH), window.innerWidth - WIDTH - MARGIN),
      vertical: below ? `top: ${rect.bottom + 6}px;` : `bottom: ${window.innerHeight - rect.top + 6}px;`,
    };
  });

  let popover: HTMLDivElement | undefined = $state();

  $effect(() => {
    popover?.querySelector<HTMLElement>(".float-row, .float-button")?.focus();
  });

  function line(summary: BridgeConversationSummary): string {
    if (summary.permission) return summary.permission.title;
    if (summary.state === "busy" || summary.state === "starting") return t("agents.row.working");
    if (summary.error) return summary.error;
    if (summary.state === "failed") return t("agents.row.failed");
    return summary.unread ? t("agents.badge.finished") : "";
  }

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const rows = Array.from(popover?.querySelectorAll<HTMLElement>(".float-row, .float-button") ?? []);
    if (rows.length === 0) return;
    event.preventDefault();
    const index = rows.indexOf(document.activeElement as HTMLElement);
    rows[(index + (event.key === "ArrowDown" ? 1 : -1) + rows.length) % rows.length]?.focus();
  }
</script>

<div
  bind:this={popover}
  class="popover float-surface float-popover"
  class:above={!position.below}
  role="dialog"
  tabindex="-1"
  aria-label={t("agents.badge.title")}
  style="{position.vertical} left: {position.left}px; width: {WIDTH}px;"
  use:portal
  use:reportInteractiveZone={{ id: "agents-popover" }}
  onkeydown={handleKeydown}
  {@attach dismissable({ onDismiss: onclose, ignore: ".agents-pill", escape: true, returnFocus: anchor })}
>
  <div class="head">
    <span class="float-popover-title">{t("agents.badge.title")}</span>
    <button
      class="float-button new"
      onclick={() => {
        onclose();
        openAskBar();
      }}
    >
      {t("agents.badge.new")}
      {#if askKeys}<span class="keys" aria-hidden="true">{askKeys}</span>{/if}
    </button>
  </div>

  <div class="list">
    {#each sections as section (section.key)}
      <div class="section" role="group" aria-label={section.label}>
        <div class="section-label" aria-hidden="true">{section.label}</div>
        {#each section.items as summary, index (summary.tabId)}
          {@const detail = line(summary)}
          {@const otherSpace = summary.spaceId !== activeSpaceId}
          <div class="item" class:waiting={!!summary.permission} style:--stagger={Math.min(section.start + index, 8)}>
            <button
              class="float-row"
              aria-label={[summary.title || t("agents.row.untitled"), detail, otherSpace ? summary.spaceName : ""].filter(Boolean).join(", ")}
              onclick={() => {
                terminalActions.reveal(summary.tabId);
                onclose();
              }}
            >
              <MascotGlyph />
              <span class="text">
                <span class="name">{summary.title || t("agents.row.untitled")}</span>
                {#if detail}<span class="detail" class:error={summary.state === "failed"}>{detail}</span>{/if}
              </span>
              {#if otherSpace}<span class="space" aria-hidden="true">{summary.spaceName}</span>{/if}
              {#if section.key === "running"}
                <span class="spinner" aria-hidden="true"></span>
              {:else if section.key === "done" && summary.unread}
                <span class="unread" aria-hidden="true"></span>
              {/if}
            </button>
            {#if summary.permission}
              <div class="answers">
                <PermissionButtons tabId={summary.tabId} requestId={summary.permission.requestId} options={summary.permission.options} />
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {:else}
      <p class="empty">{t("agents.badge.empty")}</p>
    {/each}
  </div>
</div>

<style>
  .popover {
    position: fixed;
    z-index: var(--z-popover);
    transform-origin: calc(100% - 12px) 0;
  }

  .popover.above {
    transform-origin: calc(100% - 12px) 100%;
  }

  .head {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 2px 2px 8px;
  }

  .head .float-popover-title {
    flex: 1;
  }

  .new {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }

  .keys {
    font-size: var(--font-size-2xs);
    color: var(--text-muted);
  }

  .list {
    display: flex;
    flex-direction: column;
    gap: 4px;
    max-height: 420px;
    overflow-y: auto;
  }

  .section {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .section-label {
    padding: 6px 8px 2px;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    color: var(--text-muted);
  }

  /* Rows follow the popover in, 20ms apart; the cap keeps a long list from trailing. */
  .item {
    border-radius: calc(var(--float-radius-popover) - 6px);
    animation: agents-popover-row-in var(--motion-duration-normal) var(--motion-ease-organic) both;
    animation-delay: calc(40ms + var(--stagger) * 20ms);
  }

  @keyframes agents-popover-row-in {
    from {
      opacity: 0;
      transform: translateY(-4px);
    }
  }

  .item.waiting {
    background: color-mix(in srgb, var(--attention) 9%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--attention) 35%, transparent);
  }

  .item .float-row {
    align-items: flex-start;
    padding-block: 8px;
  }

  .text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .name {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .detail {
    font-size: var(--font-size-sm);
    color: var(--text-secondary);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .detail.error {
    color: var(--danger-text);
  }

  .space {
    flex: none;
    max-width: 30%;
    padding: 1px 7px;
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-10);
    font-size: var(--font-size-xs);
    color: var(--text-muted);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .answers {
    padding: 0 8px 8px 32px;
  }

  .unread {
    flex: none;
    width: 6px;
    height: 6px;
    margin-top: 6px;
    border-radius: 50%;
    background: var(--accent);
  }

  /* About 30 s of turns, then a still arc: a turn left running must not keep the display link up. */
  .spinner {
    flex: none;
    width: 11px;
    height: 11px;
    margin-top: 3px;
    box-sizing: border-box;
    border-radius: 50%;
    border: 1.5px solid var(--text-primary-tint-12);
    border-top-color: var(--agents);
    border-right-color: var(--agents);
    animation: agents-popover-spin 0.9s linear 33 forwards;
  }

  @keyframes agents-popover-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .spinner,
    .item {
      animation: none;
    }
  }

  /* The global rule shortens animations but not their delays, which would hold rows back. */
  :global(html.reduced-power) .item {
    animation: none;
  }

  .empty {
    margin: 0;
    padding: 8px;
    font-size: var(--font-size-sm);
    color: var(--text-muted);
  }
</style>
