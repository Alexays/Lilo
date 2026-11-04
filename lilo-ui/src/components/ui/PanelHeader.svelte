<script lang="ts">
  import type { Snippet } from "svelte";
  import { chromeActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";

  interface Props {
    title: string;
    onclose: () => void;
    /** Turns the close button into a back button with this name (a system screen's way back to its Space). */
    backLabel?: string;
    /** Optional controls rendered just left of the close button (e.g. undo/redo). */
    actions?: Snippet;
  }

  let { title, onclose, backLabel, actions }: Props = $props();
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="panel-header" ondblclick={() => chromeActions.maximizeWindow()} onpointerdown={pressTabsHeader}>
  <div class="panel-header-bar">
    {#if actions}
      <div class="panel-header-actions">{@render actions()}</div>
    {/if}
    {#if backLabel !== undefined}
      <button class="panel-back" onclick={onclose}>
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path d="M7.5 2.5 4 6l3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        <span class="panel-back-label">{backLabel || t("common.back")}</span>
      </button>
    {:else}
    <button class="panel-close" onclick={onclose} aria-label={t("common.close")}>
      <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
        <path
          d="M2 2l8 8M10 2l-8 8"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
        />
      </svg>
    </button>
    {/if}
  </div>
  <h2 class="panel-title">{title}</h2>
</div>

<style>
  .panel-header {
    flex-shrink: 0;
  }

  /* Same height as the traffic lights row, so they stay centered on it. */
  .panel-header-bar {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 2px;
    height: 44px;
    padding-left: 68px;
  }

  /* Outside the default layout the lights sit on a 40pt line: page toolbar, tab strip or address-less header. */
  :global(html:not([data-tab-position='left'][data-address='tabs'])) .panel-header-bar {
    height: var(--page-toolbar-height);
    padding-left: 63px;
  }

  .panel-title {
    font-size: var(--font-size-xl);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
    margin: 0;
    padding: 0 var(--sidebar-right-pad, 10px) 6px 12px;
    overflow-wrap: anywhere;
  }

  .panel-header-actions {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  .panel-close {
    width: 28px;
    height: 28px;
    border: none;
    background: none;
    color: var(--text-muted);
    cursor: pointer;
    border-radius: var(--radius-sm);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    margin-right: var(--sidebar-right-pad, 10px);
  }

  .panel-back {
    display: flex;
    align-items: center;
    gap: var(--space-4);
    min-width: 0;
    height: var(--control-height-md);
    margin-right: auto;
    padding: 0 var(--space-8) 0 var(--space-4);
    border: none;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    cursor: pointer;
  }

  .panel-back svg {
    flex: none;
    color: var(--text-secondary);
  }

  .panel-back-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .panel-back:hover,
  .panel-close:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .panel-back:focus-visible,
  .panel-close:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
