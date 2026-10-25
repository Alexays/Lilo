<script lang="ts">
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";
  import NavControls from "../sidebar/NavControls.svelte";
  import URLDisplay from "../urlbar/URLDisplay.svelte";
  import { chromeActions } from "../../lib/bridge/actions";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { getTabPosition, isAddressInPageToolbar } from "../../stores/tabLayout.svelte";
  import { areTrafficLightsVisible } from "../../stores/ui.svelte";

  let { collapseLocked = false, row = false }: { collapseLocked?: boolean; row?: boolean } = $props();

  // The traffic lights sit top-left of the window: room for them when the toolbar starts there.
  const besideTrafficLights = $derived(!row && getTabPosition() !== "left" && areTrafficLightsVisible());
  // The sidebar keeps its toggle when it is there; bottom and top have no sidebar to hold it.
  const navShow = $derived(getTabPosition() === "bottom" ? "all" : "history");

  function startWindowDrag(event: PointerEvent) {
    if (event.button !== 0) return;
    if ((event.target as HTMLElement | null)?.closest("button, a, input, select, textarea, [role='button'], .url-display")) return;
    pressTabsHeader(event);
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="page-toolbar tabs-surface"
  class:row
  use:reportInteractiveZone={{ id: "page-toolbar" }}
  onpointerdown={startWindowDrag}
  ondblclick={(event) => {
    if (!(event.target as HTMLElement).closest("button, .url-display")) chromeActions.maximizeWindow();
  }}
>
  {#if besideTrafficLights}
    <div class="lights-spacer"></div>
  {/if}
  <!-- Under a top strip, the strip already holds the navigation: this row is the address alone. -->
  {#if !row}
    <NavControls {collapseLocked} show={navShow} />
  {/if}
  {#if isAddressInPageToolbar() || row}
    <div class="address"><URLDisplay /></div>
  {/if}
</div>

<style>
  .page-toolbar {
    position: fixed;
    top: 0;
    left: var(--chrome-content-left);
    right: var(--chrome-content-right);
    height: var(--page-toolbar-height);
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 4px;
    box-sizing: border-box;
    pointer-events: auto;
    background: var(--sidebar-bg);
    /* Over the command bar's page veil: the address drawers hang from here into the page, as they hang beside it from the sidebar. */
    z-index: 61;
  }

  .page-toolbar.row {
    top: var(--top-strip-height);
  }

  /* The sidebar header spreads its controls; the toolbar keeps them together on the left. */
  .page-toolbar > :global(.nav-controls) {
    flex: none;
    gap: 2px;
  }

  .page-toolbar > :global(.nav-controls .nav-spacer) {
    flex: 0 0 10px;
  }

  /* Matches the sidebar header's reserve for the traffic lights. */
  .lights-spacer {
    width: 72px;
    flex-shrink: 0;
  }

  /* Centered on the page, whatever sits beside it. */
  .address {
    position: absolute;
    left: 50%;
    transform: translateX(-50%);
    width: min(480px, 100% - 2 * 180px);
  }

  .address > :global(.url-display) {
    padding: 0;
  }
</style>
