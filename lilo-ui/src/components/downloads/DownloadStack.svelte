<!-- The downloads that just started or ended, stacked above the sidebar's downloads button for a few seconds: the
     pointer fans them out, a finished one drags out or opens on a click. Mounted with the deferred chrome, so the
     first frame pays nothing for it. -->
<script lang="ts">
  import { getFormatLocale, getLocale, t } from "../../lib/i18n/state.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { downloadActions } from "../../lib/bridge/actions";
  import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import { progress } from "../../lib/downloadFormat";
  import { popoverOut } from "../../lib/motion/restingTransitions";
  import { dismissDownloadStack as ondismiss, getDownloadStack } from "../../stores/downloadStack.svelte";
  import { isActiveDownload } from "../../stores/downloads.svelte";
  import { isDownloadUiEnabled } from "../../stores/extensions.svelte";
  import { isDownloadsVisible, openDownloadsPanel } from "../../stores/panels.svelte";
  import { tooltip } from "../../lib/tooltip";
  import Icon from "../ui/Icon.svelte";
  import { downloadDrag } from "./downloadDrag";
  import DownloadVisual from "./DownloadVisual.svelte";
  import { canOpen, inlineAction, metaLine, type InlineAction } from "./downloadsPanelModel";

  // Newest first.
  const downloads = $derived(getDownloadStack());

  // Above the sidebar's bottom bar and as wide as it: without one on screen (tabs on top or bottom, the rail, a
  // hidden sidebar), no stack.
  const bar = $derived.by(() => {
    if (downloads.length === 0) return undefined;
    const rect = document.querySelector(".bottom-bar")?.getBoundingClientRect();
    return rect && rect.width > 0 && rect.right > 0 && rect.left < window.innerWidth ? rect : undefined;
  });

  // The Downloads screen lists the files itself, and so does the menu the downloads button opens.
  $effect(() => {
    if (downloads.length === 0) return;
    if (!bar || isDownloadsVisible() || !isDownloadUiEnabled()) return ondismiss();
    const handleClick = (event: MouseEvent) => {
      if ((event.target as Element).closest(".download-btn-wrap")) ondismiss();
    };
    window.addEventListener("click", handleClick, true);
    return () => window.removeEventListener("click", handleClick, true);
  });

  const HOLD_MS = 6000;
  // Fanned out, and kept, while the pointer or the keyboard is on it.
  let hovered = $state(false);
  let focused = $state(false);
  const open = $derived(hovered || focused);

  // Restarts when a download joins or changes state, never on a progress tick.
  const holdKey = $derived(downloads.map((dl) => `${dl.id}:${dl.state}`).join());
  $effect(() => {
    // The stack leaves without telling the pointer or the focus that were on it.
    if (!holdKey) {
      hovered = false;
      focused = false;
    }
    if (!holdKey || open) return;
    const timer = setTimeout(ondismiss, HOLD_MS);
    return () => clearTimeout(timer);
  });

  const INLINE_LABEL_KEYS: Record<InlineAction, string> = {
    pause: "downloadsPanel.pause",
    resume: "downloadsPanel.resume",
    retry: "common.retry",
  };

  function runInlineAction(download: BridgeDownloadSnapshot, action: InlineAction): void {
    if (action === "pause") downloadActions.pause(download.id);
    if (action === "resume") downloadActions.resume(download.id);
    if (action === "retry") downloadActions.retry(download.id);
  }

  function activate(download: BridgeDownloadSnapshot): void {
    if (canOpen(download)) {
      downloadActions.open(download.id);
      ondismiss(download.id);
    } else {
      ondismiss();
      openDownloadsPanel();
    }
  }

  function showInFinder(download: BridgeDownloadSnapshot): void {
    downloadActions.showInFinder(download.id);
    ondismiss(download.id);
  }
</script>

{#if bar && downloads.length > 0}
<div
  class="download-stack"
  class:open
  style={`left: ${bar.left + 8}px; bottom: ${window.innerHeight - bar.top}px; width: ${Math.min(bar.width - 16, 280)}px;`}
  role="group"
  aria-label={t("downloadsPanel.title")}
  onpointerenter={() => (hovered = true)}
  onpointerleave={() => (hovered = false)}
  onfocusin={() => (focused = true)}
  onfocusout={() => (focused = false)}
  out:popoverOut|global
  use:reportInteractiveZone={{ id: "download-stack" }}
>
  {#each downloads as download, depth (download.id)}
    {@const meta = metaLine(download, getLocale(), getFormatLocale(), Date.now())}
    {@const action = inlineAction(download)}
    {@const openable = canOpen(download)}
    <div class="stack-card float-surface" class:draggable={openable} style:--depth={depth}>
      <button
        class="card-main"
        type="button"
        onclick={() => activate(download)}
        use:downloadDrag={{ id: openable ? download.id : null, onstart: () => ondismiss(download.id) }}
      >
        <DownloadVisual {download} size={40} />
        <span class="card-text">
          <span class="card-name">{download.filename}</span>
          {#if isActiveDownload(download)}
            <span class="card-progress" class:paused={download.state === "paused"} aria-hidden="true">
              <span class="card-progress-fill" style={`transform: scaleX(${progress(download) / 100})`}></span>
            </span>
          {/if}
          <span class="card-detail" class:failed={meta.tone === "error"}>
            {meta.errorText ?? [meta.detail, meta.stateKey && t(meta.stateKey)].filter(Boolean).join(" · ")}
          </span>
        </span>
      </button>
      {#if action}
        <button
          class="card-action"
          type="button"
          aria-label={t(INLINE_LABEL_KEYS[action])}
          use:tooltip={t(INLINE_LABEL_KEYS[action])}
          onclick={() => runInlineAction(download, action)}
        >
          <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            {#if action === "pause"}
              <path d="M5.5 3.5v9M10.5 3.5v9" />
            {:else if action === "resume"}
              <path d="M5 3.2v9.6L12.5 8z" />
            {:else}
              <path d="M13 8a5 5 0 1 1-1.6-3.7" /><path d="M13 2.5v3h-3" />
            {/if}
          </svg>
        </button>
      {/if}
      {#if isActiveDownload(download)}
        <button
          class="card-action"
          type="button"
          aria-label={t("common.cancel")}
          use:tooltip={t("common.cancel")}
          onclick={() => downloadActions.cancel(download.id)}
        >
          <Icon name="close" size={12} />
        </button>
      {:else if openable}
        <button
          class="card-action"
          type="button"
          aria-label={t("downloadsPanel.showInFinder")}
          use:tooltip={t("downloadsPanel.showInFinder")}
          onclick={() => showInFinder(download)}
        >
          <Icon name="search" size={12} />
        </button>
      {/if}
    </div>
  {/each}
</div>
{/if}

<style>
  /* Covers the end of the tab list, as wide as the bar: nothing moves to make room for it. The newest card sits
     nearest the button; at rest the older ones wait behind it, a sliver of each showing above. */
  .download-stack {
    --card-height: 60px;
    --card-gap: 6px;
    --card-peek: 5px;
    position: fixed;
    z-index: var(--z-card);
    display: flex;
    flex-direction: column-reverse;
    gap: var(--card-gap);
    /* Only the cards take the pointer at rest: the room the fan will need stays the tab list's. */
    pointer-events: none;
    animation: stack-in var(--motion-duration-normal) ease both;
  }

  .download-stack.open {
    pointer-events: auto;
  }

  @keyframes stack-in {
    from {
      opacity: 0;
      translate: 0 8px;
    }
  }

  .stack-card {
    position: relative;
    z-index: calc(10 - var(--depth));
    height: var(--card-height);
    box-sizing: border-box;
    display: flex;
    align-items: center;
    gap: 2px;
    padding-right: 8px;
    border-radius: var(--float-radius-card);
    pointer-events: auto;
    transform-origin: top center;
    translate: 0 calc(var(--depth) * (var(--card-height) + var(--card-gap) - var(--card-peek)));
    scale: calc(1 - var(--depth) * 0.05);
    transition:
      translate var(--motion-duration-normal) var(--motion-ease-spring),
      scale var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .download-stack.open .stack-card {
    translate: none;
    scale: none;
  }

  @media (prefers-reduced-motion: reduce) {
    @keyframes stack-in {
      from {
        opacity: 0;
      }
    }

    .stack-card {
      transition: none;
    }
  }

  .stack-card:hover {
    background: color-mix(in srgb, var(--text-primary) 5%, var(--float-surface));
  }

  .card-main {
    flex: 1;
    min-width: 0;
    height: 100%;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 6px 0 10px;
    border: 0;
    border-radius: inherit;
    background: none;
    color: inherit;
    font: inherit;
    text-align: left;
  }

  .draggable .card-main {
    cursor: grab;
  }

  .card-main:focus-visible,
  .card-action:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .card-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .card-name,
  .card-detail {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .card-name {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .card-detail {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
  }

  .card-detail.failed {
    color: var(--danger-text);
  }

  .card-progress {
    height: 4px;
    margin-block: 2px;
    overflow: hidden;
    border-radius: var(--radius-chip);
    background: var(--bg-hover);
  }

  .card-progress-fill {
    display: block;
    height: 100%;
    background: var(--accent);
    transform-origin: left;
    transition: transform var(--motion-duration-slow) ease;
  }

  .card-progress.paused .card-progress-fill {
    background: var(--text-muted);
  }

  @media (prefers-reduced-motion: reduce) {
    .card-progress-fill {
      transition: none;
    }
  }

  .card-action {
    flex: none;
    width: 24px;
    height: 24px;
    display: grid;
    place-items: center;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
  }

  .card-action:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }
</style>
