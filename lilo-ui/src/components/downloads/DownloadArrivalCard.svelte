<!-- The file that just finished downloading, above the downloads button for a few seconds: drag it out, click to open. -->
<script lang="ts">
  import { getFormatLocale, getLocale, t } from "../../lib/i18n/state.svelte";
  import { downloadActions } from "../../lib/bridge/actions";
  import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import { popoverOut } from "../../lib/motion/restingTransitions";
  import { tooltip } from "../../lib/tooltip";
  import Icon from "../ui/Icon.svelte";
  import { downloadDrag } from "./downloadDrag";
  import { fileIconURL, metaLine } from "./downloadsPanelModel";

  let { download, ondismiss }: { download: BridgeDownloadSnapshot; ondismiss: () => void } = $props();

  const HOLD_MS = 6000;
  // Stays while the pointer or the keyboard is on it.
  let hovered = $state(false);
  let focused = $state(false);

  $effect(() => {
    void download.id;
    if (hovered || focused) return;
    const timer = setTimeout(ondismiss, HOLD_MS);
    return () => clearTimeout(timer);
  });

  const detail = $derived(metaLine(download, getLocale(), getFormatLocale(), Date.now()).detail);

  function open(): void {
    downloadActions.open(download.id);
    ondismiss();
  }

  function showInFinder(): void {
    downloadActions.showInFinder(download.id);
    ondismiss();
  }
</script>

<div
  class="arrival-card float-surface"
  role="group"
  aria-label={t("downloadsPanel.title")}
  onpointerenter={() => (hovered = true)}
  onpointerleave={() => (hovered = false)}
  onfocusin={() => (focused = true)}
  onfocusout={() => (focused = false)}
  out:popoverOut|global
>
  <button
    class="arrival-main"
    type="button"
    onclick={open}
    use:downloadDrag={{ id: download.id, onstart: ondismiss }}
  >
    <span class="file-tile"><img src={fileIconURL(download)} alt="" width="24" height="24" draggable="false" /></span>
    <span class="arrival-text">
      <span class="arrival-name">{download.filename}</span>
      {#if detail}<span class="arrival-detail">{detail}</span>{/if}
    </span>
  </button>
  <button
    class="arrival-reveal"
    type="button"
    aria-label={t("downloadsPanel.showInFinder")}
    use:tooltip={t("downloadsPanel.showInFinder")}
    onclick={showInFinder}
  >
    <Icon name="search" size={13} />
  </button>
</div>

<style>
  /* Covers the end of the tab list, as wide as the bar: nothing moves to make room for it. */
  .arrival-card {
    position: absolute;
    left: var(--sidebar-right-pad, 8px);
    right: var(--sidebar-right-pad, 8px);
    bottom: 100%;
    max-width: 280px;
    display: flex;
    align-items: center;
    border-radius: var(--float-radius-card);
    animation: arrival-in var(--motion-duration-normal) ease both;
  }

  @keyframes arrival-in {
    from {
      opacity: 0;
      translate: 0 8px;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    @keyframes arrival-in {
      from {
        opacity: 0;
      }
    }
  }

  .arrival-main {
    flex: 1;
    min-width: 0;
    height: 52px;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 40px 0 10px;
    border: 0;
    border-radius: inherit;
    background: none;
    color: inherit;
    font: inherit;
    text-align: left;
    cursor: grab;
  }

  .arrival-main:hover {
    background: var(--bg-hover);
  }

  .arrival-main:focus-visible,
  .arrival-reveal:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .file-tile {
    flex: none;
    width: 32px;
    height: 32px;
    display: grid;
    place-items: center;
  }

  .file-tile img {
    pointer-events: none;
  }

  .arrival-text {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .arrival-name,
  .arrival-detail {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .arrival-name {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .arrival-detail {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
  }

  .arrival-reveal {
    position: absolute;
    right: 10px;
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

  .arrival-reveal:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }
</style>
