<script lang="ts">
  import { tick, untrack } from "svelte";
  import NavControls from "./NavControls.svelte";
  import URLDisplay from "../urlbar/URLDisplay.svelte";
  import SpacePage from "./SpacePage.svelte";
  import KeepAwakeIndicator from "./KeepAwakeIndicator.svelte";
  import BottomBar from "./BottomBar.svelte";
  import PipDock from "./PipDock.svelte";
  import MediaCard from "./MediaCard.svelte";
  import { chromeActions } from "../../lib/bridge/actions";
  import {
    hasActivePanel,
    isDesignSystemShellOpen,
    isSettingsShellOpen,
  } from "../../stores/panels.svelte";
  import {
    getPagedSpaces,
    getSpacePagerVirtualIndex,
    setSpacePagerElement,
  } from "../../stores/pager.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { areTrafficLightsVisible, isSidebarVisible } from "../../stores/ui.svelte";
  import { getTabPosition, hasPageToolbar, isAddressInPageToolbar } from "../../stores/tabLayout.svelte";
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";
  import { t } from "../../lib/i18n/state.svelte";

  let spaceContentEl: HTMLDivElement | undefined = $state();
  let keepAwakeWidth = $state(0);
  const spaces = $derived(getPagedSpaces());
  const visualIndex = $derived(getSpacePagerVirtualIndex());
  const isOverlayPanelOpen = $derived(
    hasActivePanel() || isSettingsShellOpen() || isDesignSystemShellOpen(),
  );

  // At rest the pager sits on an integer index and the other panes are clipped off-screen.
  const pagerAtRest = $derived(Math.abs(visualIndex - Math.round(visualIndex)) < 0.005);

  function getPaneStyle(index: number): string {
    const distance = Math.abs(index - visualIndex);
    // Hide off-screen panes outright and keep the focused pane free of blur and compositing hints.
    if (pagerAtRest) {
      return distance > 0.5 ? "visibility: hidden; opacity: 0.12;" : "opacity: 1;";
    }
    const proximity = Math.max(0, 1 - distance);
    const opacity = 0.12 + proximity * 0.88;
    // Blur is quantized (0/1.5/3/4.5px) so mid-swipe frames reuse the pane's rasterized blur
    // instead of re-blurring at a new radius every frame; the 220ms filter transition eases
    // between steps. Opacity stays continuous: it composites for free.
    const blur = Math.round(((1 - proximity) * 4.5) / 1.5) * 1.5;
    const willChange = distance <= 1.5 ? "will-change: opacity, filter; " : "";
    const filter = blur > 0 ? ` filter: blur(${blur}px);` : "";
    return `${willChange}opacity: ${opacity.toFixed(3)};${filter}`;
  }

  $effect(() => {
    setSpacePagerElement(spaceContentEl);
  });

  $effect(() => {
    chromeActions.setSidebarCollapseLocked(isOverlayPanelOpen);
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
      <!-- Floating in while hidden, the sidebar brings back what the unmounted page toolbar holds. -->
      <NavControls collapseLocked={isOverlayPanelOpen} show={isSidebarVisible() && hasPageToolbar() ? "toggle" : "all"} />
    </div>
    {#if !(isSidebarVisible() && isAddressInPageToolbar())}
      <URLDisplay />
    {/if}

    <!-- Space content: native horizontal scroll with snap paging -->
    <div class="space-content" style={`--keep-awake-reserve: ${keepAwakeWidth ? keepAwakeWidth + 8 : 0}px;`}>
      <!-- Over the Space header but outside the pages: it does not swipe, it is about the Mac. -->
      <div class="keep-awake-slot" bind:clientWidth={keepAwakeWidth}>
        <KeepAwakeIndicator />
      </div>
      <div class="space-track" bind:this={spaceContentEl}>
        <div class="space-slider">
          {#each spaces as space, index (space.id)}
            <div
              class="space-pane"
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
    <MediaCard />

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
    overflow: hidden;
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
    height: var(--page-toolbar-height);
  }

  .compact-header .sidebar-header :global(.nav-controls) {
    flex: none;
    margin-left: auto;
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
    /* Keeps the keep-awake chip's z-index local, so the URL bar's details card covers it. */
    isolation: isolate;
  }

  /* Centred on the Space header's row, aligned with its right edge. */
  .keep-awake-slot {
    position: absolute;
    top: 8px;
    right: calc(var(--sidebar-right-pad, 10px) + 6px);
    z-index: 20;
  }

  .space-track {
    flex: 1;
    min-height: 0;
    overflow-x: auto;
    overflow-y: hidden;
    position: relative;
    scroll-snap-type: x mandatory;
    scroll-behavior: smooth;
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
    transition:
      opacity var(--motion-duration-fast) linear,
      filter 220ms var(--motion-ease-spring);
  }

  /* A hidden neighbor pane stays mounted: its looping animations would still tick unseen. */
  .space-pane.pane-hidden :global(*),
  .space-pane.pane-hidden :global(*::before),
  .space-pane.pane-hidden :global(*::after) {
    animation-play-state: paused !important;
  }

  .sidebar-header {
    display: flex;
    align-items: center;
    height: 52px;
    padding: 0 var(--sidebar-right-pad, 10px) 0 0;
    flex-shrink: 0;
  }

  /* Reserve space for macOS traffic light buttons */
  .header-spacer {
    width: 85px;
    flex-shrink: 0;
    transition: width 220ms var(--motion-ease-spring);
  }

  /* Full screen: the toggle lines up with the URL field below it. */
  .sidebar-header.no-traffic-lights .header-spacer {
    width: 10px;
  }
</style>
