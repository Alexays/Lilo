<script lang="ts">
  import { tick, untrack } from "svelte";
  import NavControls from "./NavControls.svelte";
  import URLDisplay from "../urlbar/URLDisplay.svelte";
  import SpacePage from "./SpacePage.svelte";
  import BottomBar from "./BottomBar.svelte";
  import PipDock from "./PipDock.svelte";
  import MediaCard from "./MediaCard.svelte";
  import { getCallCardTab } from "../../stores/media.svelte";
  import { chromeActions } from "../../lib/bridge/actions";
  import {
    hasActivePanel,
    isDesignSystemShellOpen,
    isHistoryShellOpen,
    isSettingsShellOpen,
  } from "../../stores/panels.svelte";
  import {
    getPagedSpaces,
    getSpacePagerVirtualIndex,
    setSpacePagerElement,
  } from "../../stores/pager.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { getReadyUpdate, getSetting } from "../../stores/settings.svelte";
  import { areTrafficLightsVisible, isSidebarVisible } from "../../stores/ui.svelte";
  import { getAddressPlacement, getTabPosition, hasPageToolbar, isAddressInPageToolbar, isAddressVisible } from "../../stores/tabLayout.svelte";
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";
  import { t } from "../../lib/i18n/state.svelte";

  let spaceContentEl: HTMLDivElement | undefined = $state();
  const spaces = $derived(getPagedSpaces());
  const visualIndex = $derived(getSpacePagerVirtualIndex());
  const isOverlayPanelOpen = $derived(
    hasActivePanel() || isSettingsShellOpen() || isDesignSystemShellOpen() || isHistoryShellOpen(),
  );

  // At rest the pager sits on an integer index and the other panes are clipped off-screen.
  const pagerAtRest = $derived(Math.abs(visualIndex - Math.round(visualIndex)) < 0.005);

  function getPaneStyle(index: number): string {
    const distance = Math.abs(index - visualIndex);
    if (pagerAtRest) {
      return distance > 0.5 ? "visibility: hidden; opacity: 0.12;" : "opacity: 1;";
    }
    const proximity = Math.max(0, 1 - distance);
    // Mid-swipe the opacity follows the finger frame by frame. The blur moves in three steps, so its
    // style, and its transition, change three times a swipe rather than every frame.
    const blur = Math.round(((1 - proximity) * 4.5) / 1.5) * 1.5;
    return `opacity: ${(0.12 + proximity * 0.88).toFixed(3)};${blur > 0 ? ` filter: blur(${blur}px);` : ""}`;
  }

  $effect(() => {
    setSpacePagerElement(spaceContentEl);
  });

  // The tab strip unmounts the sidebar with a panel still open: the lock goes with it.
  $effect(() => {
    if (!isOverlayPanelOpen) return;
    chromeActions.setSidebarCollapseLocked(true);
    return () => chromeActions.setSidebarCollapseLocked(false);
  });

  // Before the sidebar goes inert, note what had the focus; once the panel closes the focus goes
  // back there, unless the panel already sent it somewhere else.
  $effect.pre(() => {
    if (!isOverlayPanelOpen) return;
    const focused = untrack(() => document.activeElement);
    const opener = focused instanceof HTMLElement && focused !== document.body ? focused : null;
    return () => {
      void tick().then(() => {
        const now = document.activeElement;
        const lost = !now || now === document.body || !!now.closest(".sidebar-panel");
        if (opener?.isConnected && lost) opener.focus({ preventScroll: true });
      });
    };
  });

  // Kept out of the first frame: loaded with the first update, then kept so its close still animates.
  let updateCardLoaded = $state(false);
  $effect(() => {
    if (getReadyUpdate()) updateCardLoaded = true;
  });

  // Latched on first open: the panels chunk loads once, then stays mounted so close animations
  // and later opens keep working.
  let panelsLoaded = $state(false);
  $effect(() => {
    if (isOverlayPanelOpen) panelsLoaded = true;
  });
</script>

<div class="sidebar-viewport">
  <div
    class="sidebar-layout"
    class:pushed={isOverlayPanelOpen}
    class:compact-header={isSidebarVisible() && hasPageToolbar()}
    class:address-corner={getTabPosition() === "left" && getAddressPlacement() === "tabs"}
    inert={isOverlayPanelOpen}
    role="complementary"
    aria-label={t("sidebar.ariaLabel")}
  >
    <!-- Fixed header: does NOT swipe -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <!-- On the right, the traffic lights and the history buttons live in the page toolbar. -->
    <div
      class="sidebar-header"
      class:no-traffic-lights={!areTrafficLightsVisible() || getTabPosition() === "right"}
      ondblclick={() => chromeActions.maximizeWindow()}
      onpointerdown={pressTabsHeader}
    >
      <div class="header-spacer"></div>
      <!-- Floating in while hidden, the sidebar brings back what the unmounted page toolbar holds. On the
           left, the page toolbar stays with the sidebar hidden and holds the toggle ahead of the history buttons. -->
      {#if !hasPageToolbar() || getTabPosition() !== "left"}
        <NavControls collapseLocked={isOverlayPanelOpen} show={isSidebarVisible() && hasPageToolbar() ? "toggle" : "all"} />
      {/if}
      <!-- Loaded only once the feature is on: no conversation code ships to the chrome otherwise. -->
      {#if getSetting("agentsEnabled", "false") === "true"}
        <div class="agents-slot">
          {#await import("../agents/AgentsBadge.svelte") then badge}
            <badge.default />
          {/await}
        </div>
      {/if}
      <!-- With the address hidden, the page's buttons stay on the header's line. -->
      {#if !isAddressVisible()}
        <div class="page-actions">
          <URLDisplay actionsOnly />
        </div>
      {/if}
    </div>
    {#if isAddressVisible() && !isAddressInPageToolbar()}
      <URLDisplay />
    {/if}

    <!-- Space content: native horizontal scroll with snap paging -->
    <div class="space-content">
      <div class="space-track" bind:this={spaceContentEl}>
        <div class="space-slider">
          {#each spaces as space, index (space.id)}
            <div
              class="space-pane"
              class:resting={pagerAtRest}
              class:pane-hidden={pagerAtRest && Math.abs(index - visualIndex) > 0.5}
              style={getPaneStyle(index)}
            >
              <!-- Only the focused pane and its immediate neighbors stay mounted. -->
              {#if Math.abs(index - Math.round(visualIndex)) <= 1}
                <SpacePage
                  spaceId={space.id}
                  interactive={space.id === getActiveSpaceId()}
                  {index}
                />
              {/if}
            </div>
          {/each}
        </div>
      </div>
    </div>

    <!-- Fixed above the bottom bar: does NOT swipe -->
    <PipDock />
    <!-- Loaded with the first call: it costs the chrome's first frame nothing. -->
    {#if getCallCardTab()}
      {#await import("./CallCard.svelte") then card}
        <card.default />
      {/await}
    {/if}
    <MediaCard />
    {#if updateCardLoaded}
      {#await import("./UpdateCard.svelte") then card}
        <card.default />
      {/await}
    {/if}

    <!-- Fixed bottom bar: does NOT swipe -->
    <BottomBar />
  </div>

  {#if panelsLoaded}
    {#await import("./SidebarPanels.svelte") then panels}
      <panels.default active={isOverlayPanelOpen} />
    {/await}
  {/if}
</div>

<style>
  .sidebar-viewport {
    position: relative;
    /* clip, not hidden: a focus reveal while a panel slides in would scroll it, with no way back. */
    overflow: clip;
    height: 100%;
    contain: content;
  }

  /* The address details card grows past a narrow sidebar, over the page; the clip only matters while
     a side panel slides, which the card never shows over. */
  .sidebar-viewport:has(:global(.url-details)) {
    overflow: visible;
    contain: layout style;
  }

  .sidebar-layout {
    position: relative;
    display: flex;
    flex-direction: column;
    height: 100%;
    padding-top: 0;
    transition:
      transform 220ms var(--motion-ease-spring),
      opacity var(--motion-duration-normal) ease;
  }

  /* With a page toolbar beside it, the header holds only the lights and the toggle, on that toolbar's line. */
  .compact-header .sidebar-header {
    height: calc(var(--page-toolbar-height) - var(--content-inset));
    margin-top: var(--content-inset);
  }

  .compact-header .sidebar-header :global(.nav-controls) {
    flex: none;
    margin-left: auto;
  }

  /* On the right the toggle keeps the row's end, and the page's buttons sit before it. */
  .compact-header .page-actions {
    order: -1;
    margin-left: auto;
  }

  .compact-header .sidebar-header:has(.page-actions) :global(.nav-controls) {
    margin-left: 0;
  }

  .sidebar-layout.pushed {
    transform: translateX(-30%);
    opacity: 0;
    pointer-events: none;
  }

  .space-content {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
    position: relative;
    /* Keeps the pages' z-index local, so the URL bar's details card covers them. */
    isolation: isolate;
  }

  .page-actions {
    flex: none;
    height: 28px;
    margin-left: 4px;
    display: flex;
    align-items: center;
    gap: 4px;
  }

  /* Like the address bar, the page's buttons show on hover of their line; only the extensions stay out. */
  .sidebar-header:is(:hover, :focus-within) :global(.url-actions-reveal) {
    opacity: 1;
    pointer-events: auto;
    transform: translateY(-50%) translateX(0) scale(1);
  }

  .space-track {
    flex: 1;
    min-height: 0;
    overflow-x: auto;
    overflow-y: hidden;
    position: relative;
    scroll-snap-type: x mandatory;
    overscroll-behavior-x: contain;
    overscroll-behavior-y: none;
    scrollbar-width: none;
  }

  /* WebKit autoscrolls the pager toward a pointer dragged past the sidebar, paging to the next Space. */
  :global(html.sidebar-dnd-active) .space-track {
    overflow-x: hidden;
  }

  .space-track::-webkit-scrollbar {
    display: none;
  }

  .space-slider {
    display: flex;
    width: max-content;
    min-width: 100%;
    height: 100%;
  }

  .space-pane {
    flex: 0 0 calc(var(--sidebar-fitted-width, 260px) + var(--content-inset, 8px));
    width: calc(var(--sidebar-fitted-width, 260px) + var(--content-inset, 8px));
    height: 100%;
    display: flex;
    flex-direction: column;
    min-width: 0;
    scroll-snap-align: start;
    scroll-snap-stop: always;
    /* A stable layer: one created at the start of each swipe and dropped at its end hitches both ends. */
    will-change: opacity, filter;
    transition: filter 220ms var(--motion-ease-spring);
  }

  /* Opacity eases only at rest: a transition restarted by every swipe frame would trail the finger. */
  .resting {
    transition:
      opacity var(--motion-duration-fast) linear,
      filter 220ms var(--motion-ease-spring);
  }

  /* A hidden neighbor pane stays mounted: its looping animations would still tick unseen. Only the
     looping ones are named (the skeleton pauses itself), so hiding a pane restyles a few nodes, not every row. */
  .space-pane.pane-hidden :global(:is(.mascot *, .tab-loader span, .hang-icon)) {
    animation-play-state: paused !important;
  }

  .sidebar-header {
    display: flex;
    align-items: center;
    height: 52px;
    padding: 0 var(--sidebar-right-pad, 8px) 0 0;
    flex-shrink: 0;
  }

  /* The default layout lifts the lights 4pt, the address bar following them. */
  .address-corner .sidebar-header {
    height: 44px;
  }

  .address-corner > :global(.url-display) {
    padding-top: 0;
  }

  /* Reserve space for macOS traffic light buttons, 15pt in from the window's edge. */
  .agents-slot {
    flex: none;
    display: flex;
  }

  /* Without the navigation buttons to fill the line, the badge still keeps its end. */
  .header-spacer + .agents-slot {
    margin-left: auto;
  }

  .header-spacer {
    width: 81px;
    flex-shrink: 0;
    transition: width 220ms var(--motion-ease-spring);
  }

  /* Full screen: the toggle lines up with the URL field below it. */
  .sidebar-header.no-traffic-lights .header-spacer {
    width: 10px;
  }
</style>
