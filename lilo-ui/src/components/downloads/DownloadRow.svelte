<script lang="ts">
  import { t, getFormatLocale, getLocale } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { downloadActions } from "../../lib/bridge/actions";
  import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import { progress } from "../../lib/downloadFormat";
  import { isActiveDownload } from "../../stores/downloads.svelte";
  import { downloadDrag } from "./downloadDrag";
  import DownloadVisual from "./DownloadVisual.svelte";
  import {
    canOpen,
    inlineAction,
    metaLine,
    type InlineAction,
  } from "./downloadsPanelModel";

  interface Props {
    download: BridgeDownloadSnapshot;
    selected: boolean;
    onselect: () => void;
    onmenu: (anchor: DOMRect) => void;
  }

  let { download, selected, onselect, onmenu }: Props = $props();

  const INLINE_LABEL_KEYS: Record<InlineAction, string> = {
    pause: "downloadsPanel.pause",
    resume: "downloadsPanel.resume",
    retry: "common.retry",
  };

  const meta = $derived(metaLine(download, getLocale(), getFormatLocale(), Date.now()));
  const action = $derived(inlineAction(download));
  const openable = $derived(canOpen(download));
  const isActive = $derived(isActiveDownload(download));

  function runInlineAction(event: MouseEvent): void {
    event.stopPropagation();
    if (action === "pause") downloadActions.pause(download.id);
    if (action === "resume") downloadActions.resume(download.id);
    if (action === "retry") downloadActions.retry(download.id);
  }

  function handleMenuClick(event: MouseEvent): void {
    event.stopPropagation();
    onmenu((event.currentTarget as HTMLElement).getBoundingClientRect());
  }

  function handleContextMenu(event: MouseEvent): void {
    event.preventDefault();
    onselect();
    onmenu(new DOMRect(event.clientX, event.clientY, 0, 0));
  }
</script>

<!-- The row's controls sit side by side, none inside another: the main button stretches over the
     whole row under the others, so a click anywhere else still selects. -->
<div
  class="download-row"
  class:selected
  class:error={meta.tone === "error"}
  class:missing={download.fileMissing}
>
  <button
    class="file-icon"
    class:draggable={openable}
    type="button"
    aria-label={t("downloadsPanel.dragFile")}
    disabled={!openable}
    onclick={onselect}
    onpointerdown={() => {
      if (openable) downloadActions.startDrag(download.id);
    }}
  >
    <DownloadVisual {download} size={40} />
  </button>

  <button
    class="row-main"
    type="button"
    onclick={onselect}
    ondblclick={() => openable && downloadActions.open(download.id)}
    oncontextmenu={handleContextMenu}
    use:downloadDrag={{ id: openable ? download.id : null }}
    onkeydown={(event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        if (openable) downloadActions.open(download.id);
      }
    }}
  >
    <span class="row-name" use:tooltip={download.filename}>{download.filename}</span>
    {#if meta.errorText}
      <span class="row-meta tone-error" use:tooltip={meta.errorText}>{meta.errorText}</span>
    {:else}
      <span class="row-meta" class:tone-error={meta.tone === "error"}>
        {[meta.detail, meta.stateKey && t(meta.stateKey)].filter(Boolean).join(" · ")}
      </span>
    {/if}
    {#if isActive}
      <span class="row-progress" class:paused={download.state === "paused"} aria-hidden="true">
        <span class="row-progress-fill" style={`transform: translateX(${progress(download) - 100}%)`}></span>
      </span>
    {/if}
  </button>

  {#if action}
    <button
      class="row-button row-action"
      type="button"
      aria-label={t(INLINE_LABEL_KEYS[action])}
      use:tooltip={t(INLINE_LABEL_KEYS[action])}
      onclick={runInlineAction}
    >
      <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
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

  <button
    class="row-button row-menu"
    type="button"
    aria-label={t("downloadsPanel.moreActions")}
    onclick={handleMenuClick}
  >
    <svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor" aria-hidden="true">
      <circle cx="2.5" cy="7" r="1.3" />
      <circle cx="7" cy="7" r="1.3" />
      <circle cx="11.5" cy="7" r="1.3" />
    </svg>
  </button>
</div>

<style>
  /* An object row: 40 px file icon, name, one detail line, the accessories on the right. Its hover
     reaches past the content edge so the icon lines up with the page title. */
  .download-row {
    position: relative;
    display: flex;
    align-items: center;
    gap: 14px;
    min-height: 56px;
    margin-inline: -12px;
    padding: 8px 12px;
    border-radius: var(--radius-md);
    outline: none;
    cursor: default;
    transition: background var(--motion-duration-fast) ease;
  }

  .download-row:hover,
  .download-row.selected {
    background: var(--bg-hover);
  }

  .download-row:has(.row-main:focus-visible) {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .download-row.missing .file-icon,
  .download-row.missing .row-name {
    opacity: 0.5;
  }

  .file-icon {
    position: relative;
    z-index: 1;
    display: grid;
    place-items: center;
    width: 40px;
    height: 40px;
    border: 0;
    background: none;
    padding: 0;
    flex-shrink: 0;
  }

  .file-icon.draggable:not(:disabled) {
    cursor: grab;
  }

  .file-icon:disabled {
    opacity: 1;
  }

  .row-main {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    padding: 0;
    background: none;
    border: none;
    outline: none;
    text-align: left;
    color: inherit;
    font: inherit;
    cursor: default;
  }

  .row-main::after {
    content: "";
    position: absolute;
    inset: 0;
  }

  .row-name {
    display: block;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    line-height: 1.3;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .row-meta {
    display: block;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    line-height: 1.3;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .row-meta.tone-error {
    color: var(--danger-text);
  }

  .row-button {
    position: relative;
    z-index: 1;
    flex-shrink: 0;
    width: var(--control-height-sm);
    height: var(--control-height-sm);
    display: grid;
    place-items: center;
    padding: 0;
    background: none;
    border: none;
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    cursor: pointer;
  }

  .row-button:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .row-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .download-row.error .row-action {
    color: var(--danger-text);
  }

  .row-progress {
    display: block;
    width: min(100%, 420px);
    height: 4px;
    margin-top: 4px;
    border-radius: var(--radius-chip);
    overflow: hidden;
    background: var(--text-primary-tint-10);
  }

  .row-progress-fill {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--accent);
    /* Sliding a full-width fill under the clipping track keeps its rounded end undistorted. */
    transition: transform var(--motion-duration-normal) ease;
  }

  .row-progress.paused .row-progress-fill {
    background: color-mix(in srgb, var(--text-muted) 72%, transparent);
  }

  @media (prefers-reduced-motion: reduce) {
    .row-progress-fill {
      transition: none;
    }
  }
</style>
