<script lang="ts">
  import type { Snippet } from "svelte";
  import { chromeActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";
  import Icon from "./Icon.svelte";

  interface Props {
    title: string;
    onclose: () => void;
    /** Optional controls rendered just left of the close button (e.g. undo/redo). */
    actions?: Snippet;
  }

  let { title, onclose, actions }: Props = $props();
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="panel-header" ondblclick={() => chromeActions.maximizeWindow()} onpointerdown={pressTabsHeader}>
  <div class="panel-header-bar">
    {#if actions}
      <div class="panel-header-actions">{@render actions()}</div>
    {/if}
    <button class="panel-close" onclick={onclose} aria-label={t("common.close")}>
      <Icon name="close" size={16} />
    </button>
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

  .panel-close:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .panel-close:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
