<script lang="ts">
  import BookmarkedTabs from "./BookmarkedTabs.svelte";
  import TabSection from "./TabSection.svelte";
  import UndoCloseToast from "./UndoCloseToast.svelte";
  import SpaceBar from "../spaces/SpaceBar.svelte";
  import SidebarDropDock from "./SidebarDropDock.svelte";
  import SelectionIndicator from "./SelectionIndicator.svelte";
  import { chromeActions } from "../../lib/bridge/actions";
  import { getActiveTabId, getTabsById, isSpaceHydrated } from "../../stores/tabs.svelte";
  import { getSpacePagerVirtualIndex } from "../../stores/pager.svelte";
  import { isChromaticHex } from "../../lib/sidebarTheme";

  let {
    spaceId,
    interactive,
    index,
  }: { spaceId: string; interactive: boolean; index: number } = $props();

  // Mounted neighbour panes rest at distance 1 (minus sub-pixel scroll residue), so the
  // strict `< 0.98` keeps their skeletons paused while idle; a swipe brings the incoming
  // pane below 1 and animates it only while it is actually being revealed.
  const isShimmering = $derived(
    Math.abs(index - getSpacePagerVirtualIndex()) < 0.98,
  );

  const hydrated = $derived(isSpaceHydrated(spaceId));

  // Each row owns its active highlight (TabItem `.active`); this component only flies a
  // one-shot travel ghost between rows on activation, across the pinned/unpinned boundary.
  const activeTabId = $derived(getActiveTabId(spaceId));
  const activeTint = $derived.by((): string => {
    if (!activeTabId) return "";
    const color = getTabsById(spaceId).get(activeTabId)?.faviconDominantColor;
    return color && isChromaticHex(color) ? color : "";
  });
  let spaceStackEl: HTMLDivElement | undefined = $state();
  let spaceScrollEl: HTMLDivElement | undefined = $state();
  let spaceScrollContentEl: HTMLDivElement | undefined = $state();
  let scrollViewportHeight = $state(0);
  let showTopScrollCue = $state(false);
  let showBottomScrollCue = $state(false);

  function updateScrollCues(): void {
    const el = spaceScrollEl;
    if (!el) {
      showTopScrollCue = false;
      showBottomScrollCue = false;
      return;
    }
    const maxScrollTop = Math.max(0, el.scrollHeight - el.clientHeight);
    showTopScrollCue = el.scrollTop > 10;
    showBottomScrollCue = maxScrollTop - el.scrollTop > 10;
  }

  $effect(() => {
    const el = spaceScrollEl;
    const content = spaceScrollContentEl;
    if (!el || !content) return;
    el.addEventListener("scroll", updateScrollCues, { passive: true });
    const observer = new ResizeObserver(updateScrollCues);
    observer.observe(content);
    return () => {
      el.removeEventListener("scroll", updateScrollCues);
      observer.disconnect();
    };
  });

  $effect(() => {
    void scrollViewportHeight;
    updateScrollCues();
  });

  function isBlockedContextTarget(target: EventTarget | null): boolean {
    if (!(target instanceof Element)) return false;
    return target.closest(
      "button,a,input,textarea,select,[role='treeitem'],[role='button'],[data-space-context-menu-ignore='true']",
    ) !== null;
  }

  function openContextMenu(event: MouseEvent): void {
    if (!interactive || isBlockedContextTarget(event.target)) {
      return;
    }

    event.preventDefault();
    chromeActions.showSidebarContextMenu({
      x: event.clientX,
      y: event.clientY,
      width: 1,
      height: 1,
      spaceId,
    });
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="space-page" oncontextmenu={openContextMenu}>
  <div class="space-bar-slot">
    <SpaceBar {spaceId} {interactive} />
    {#if hydrated}
      <SidebarDropDock {spaceId} />
    {/if}
  </div>
  {#if hydrated}
    <div class="space-stack" bind:this={spaceStackEl}>
      <SelectionIndicator
        activeTabId={activeTabId}
        container={spaceStackEl}
        tint={activeTint}
        {spaceId}
      />
      <div class="space-stack-section">
        <BookmarkedTabs {spaceId} {interactive} />
      </div>
      <div class="space-scroll-shell">
        <div
          class="space-scroll"
          class:fade-top={showTopScrollCue}
          class:fade-bottom={showBottomScrollCue}
          bind:this={spaceScrollEl}
          bind:clientHeight={scrollViewportHeight}
        >
          <div class="space-scroll-content" bind:this={spaceScrollContentEl}>
            <div class="space-stack-section">
              <TabSection
                section="pinned"
                {spaceId}
                {interactive}
              />
            </div>
            <div class="space-stack-section space-stack-section-fill">
              <TabSection
                section="unpinned"
                {spaceId}
                {interactive}
                scroller={spaceScrollEl}
                scrollerHeight={scrollViewportHeight}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
  {:else}
    <div class="space-page-skeleton" class:shimmer-paused={!isShimmering} aria-hidden="true">
      <div class="skeleton-tab-row">
        <div class="skeleton-tab-icon skeleton-shimmer"></div>
        <div class="skeleton-tab-title skeleton-shimmer"></div>
        <div class="skeleton-tab-close skeleton-shimmer"></div>
      </div>
      <div class="skeleton-new-tab-row">
        <div class="skeleton-new-tab-plus skeleton-shimmer"></div>
        <div class="skeleton-new-tab-label skeleton-shimmer"></div>
      </div>
    </div>
  {/if}
  {#if interactive}
    <UndoCloseToast />
  {/if}
</div>

<style>
  .space-bar-slot {
    position: relative;
    flex-shrink: 0;
  }

  .space-bar-slot > :global(:first-child) {
    transition: opacity var(--motion-duration-normal) var(--motion-ease-organic);
  }

  /* The drop dock replaces the space header while it is up. */
  .space-bar-slot:has(:global(.drop-dock.visible)) > :global(:first-child) {
    opacity: 0;
  }

  .space-page {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
    position: relative;
  }

  .space-stack {
    position: relative;
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  .space-stack-section {
    position: relative;
    min-width: 0;
    overflow: visible;
    flex: 0 0 auto;
  }

  /* Grows into the spare viewport height so the empty area below the last tab
     stays a drop target, but never shrinks below its content. */
  .space-stack-section-fill {
    flex: 1 0 auto;
    display: flex;
    flex-direction: column;
  }

  .space-scroll-shell {
    position: relative;
    flex: 1;
    min-height: 0;
  }

  /* Pinned and unpinned rows share one scroller: pinned tabs scroll away with
     the rest instead of squeezing the open-tab list to nothing. */
  .space-scroll {
    height: 100%;
    overflow-y: scroll;
    overflow-x: hidden;
    overscroll-behavior-y: contain;
    /* The tab list swaps spacers for rows as it scrolls; scroll anchoring would shift the
       position to compensate and pull the window away from where the user scrolled. */
    overflow-anchor: none;
    /* `scroll` keeps the 4px scrollbar's gutter even with nothing to scroll (WebKit ignores
       scrollbar-gutter here); it comes out of the 10px right pad so rows never shift and stay symmetric. */
    --sidebar-right-pad: 6px;
    --fade-top: 0px;
    --fade-bottom: 0px;
    /* Fades the rows themselves, so the cue matches any space tint behind them. */
    mask-image: linear-gradient(
      to bottom,
      transparent,
      #000 var(--fade-top),
      #000 calc(100% - var(--fade-bottom)),
      transparent
    );
  }

  .space-scroll.fade-top {
    --fade-top: 24px;
  }

  .space-scroll.fade-bottom {
    --fade-bottom: 24px;
  }

  .space-scroll::-webkit-scrollbar {
    width: 4px;
  }

  .space-scroll::-webkit-scrollbar-thumb {
    background: var(--text-muted);
    border-radius: var(--radius-2xs);
  }

  .space-scroll-content {
    display: flex;
    flex-direction: column;
    min-height: 100%;
  }

  .space-page-skeleton {
    flex: 1;
    padding: 4px var(--sidebar-right-pad, 10px) 0 8px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .skeleton-tab-row,
  .skeleton-new-tab-row {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 28px;
    padding: 0 10px;
    border-radius: var(--radius-md);
  }

  .skeleton-tab-row {
    background: color-mix(in srgb, var(--bg-active) 82%, transparent);
    box-shadow: 0 10px 18px
      color-mix(in srgb, var(--text-primary) 8%, transparent);
  }

  .skeleton-new-tab-row {
    width: 132px;
  }

  .skeleton-tab-icon,
  .skeleton-tab-close,
  .skeleton-new-tab-plus {
    flex-shrink: 0;
    border-radius: var(--radius-chip);
  }

  .skeleton-tab-icon {
    width: 18px;
    height: 18px;
  }

  .skeleton-tab-title {
    flex: 1;
    height: 14px;
    border-radius: var(--radius-chip);
  }

  .skeleton-tab-close {
    width: 22px;
    height: 22px;
    border-radius: var(--radius-sm);
  }

  .skeleton-new-tab-plus {
    width: 12px;
    height: 12px;
  }

  .skeleton-new-tab-label {
    width: 78px;
    height: 12px;
    border-radius: var(--radius-chip);
  }

  .space-page-skeleton.shimmer-paused .skeleton-shimmer {
    animation-play-state: paused;
  }

  .skeleton-shimmer {
    position: relative;
    overflow: hidden;
  }

  /* Three 220% gradient tiles slid by a transform, so the shimmer composites instead of
     repainting each block; the 40% travel matches a -20% to 200% background-position sweep. */
  .skeleton-shimmer::before {
    content: "";
    position: absolute;
    top: 0;
    bottom: 0;
    left: -460%;
    width: 660%;
    background: linear-gradient(
      100deg,
      color-mix(in srgb, var(--bg-hover) 84%, white 16%) 0%,
      color-mix(in srgb, var(--bg-hover) 96%, white 4%) 38%,
      color-mix(in srgb, var(--bg-hover) 82%, white 18%) 62%,
      color-mix(in srgb, var(--bg-hover) 92%, transparent) 100%
    );
    background-size: calc(100% / 3) 100%;
    animation: space-skeleton-shimmer 1.35s linear infinite;
    /* Pause rules target .skeleton-shimmer itself, and play state does not inherit by default. */
    animation-play-state: inherit;
  }

  @keyframes space-skeleton-shimmer {
    from {
      transform: translateX(0);
    }

    to {
      transform: translateX(40%);
    }
  }
</style>
