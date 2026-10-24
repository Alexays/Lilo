<script lang="ts">
  import { onDestroy, untrack } from "svelte";
  import { computeIndicatorRect, type IndicatorRect } from "../../lib/motion/selectionIndicator";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import { getSelectionTravelTarget, setSelectionTravelTarget } from "../../stores/selectionTravel.svelte";
  import { getTabsById } from "../../stores/tabs.svelte";

  let {
    activeTabId,
    container,
    tint,
    spaceId,
  }: {
    activeTabId: string | null;
    /**
     * Common ancestor of every tab section (the `.space-stack`). The travel ghost is
     * positioned within it so a single flight can cross the pinned/unpinned boundary.
     */
    container: HTMLElement | undefined;
    /** Active tab's chromatic favicon color, applied as --tab-tint; empty falls back to the space accent. */
    tint: string;
    spaceId: string;
  } = $props();

  // One-shot travel ghost: the persistent highlight lives on the row (TabItem `.active`), so structural shifts need
  // no follow logic here outside the 220ms flight.
  let flight = $state<{ from: IndicatorRect; to: IndicatorRect; tint: string } | null>(null);
  let flightTimeout: ReturnType<typeof setTimeout> | null = null;
  let previousActiveTabId: string | null = null;
  // The travel target is global and neighbour SpacePage instances mount and unmount mid-swipe:
  // each one clears only the target it set itself.
  let ownTravelTarget: string | null = null;

  function releaseTravelTarget(): void {
    if (ownTravelTarget !== null && getSelectionTravelTarget() === ownTravelTarget) {
      setSelectionTravelTarget(null);
    }
    ownTravelTarget = null;
  }

  function rowFor(tabId: string): HTMLElement | null {
    if (!container) return null;
    const row = container.querySelector<HTMLElement>(
      `[data-tab-id="${CSS.escape(tabId)}"]`,
    );
    return row && row.offsetHeight > 0 ? row : null;
  }

  // Fully visible inside the inner scroller (if any). An activation that needs to scroll
  // skips the ghost: the scroll carries the eye, and the target rect would be stale
  // mid-scroll anyway.
  function isRowInView(row: HTMLElement): boolean {
    const scroller = row.closest<HTMLElement>(".space-scroll");
    if (!scroller) return true;
    const rowRect = row.getBoundingClientRect();
    const scrollerRect = scroller.getBoundingClientRect();
    return (
      rowRect.top >= scrollerRect.top - 1 &&
      rowRect.bottom <= scrollerRect.bottom + 1
    );
  }

  function rectFor(row: HTMLElement): IndicatorRect {
    const rowRect = row.getBoundingClientRect();
    const containerRect = container!.getBoundingClientRect();
    return computeIndicatorRect(
      { top: rowRect.top, left: rowRect.left, width: rowRect.width, height: row.offsetHeight },
      { top: containerRect.top, left: containerRect.left },
      0,
    );
  }

  function endFlight(): void {
    if (flightTimeout) {
      clearTimeout(flightTimeout);
      flightTimeout = null;
    }
    flight = null;
    releaseTravelTarget();
  }

  function handleActivation(next: string | null, prev: string | null): void {
    endFlight();
    if (!container || !next || !prev || prev === next) return;
    if (prefersReducedMotion()) return;
    if (document.body.classList.contains("sidebar-dnd-active")) return;
    // Close-driven activation: the predecessor is gone (or a closed pinned/bookmarked
    // survivor) and the list is collapsing under the flight path: highlight the successor
    // in place instead of flying to a rect that is about to move.
    const previousTab = getTabsById(spaceId).get(prev);
    if (!previousTab || previousTab.isClosed) return;
    const fromRow = rowFor(prev);
    const toRow = rowFor(next);
    if (!fromRow || !toRow || !isRowInView(fromRow) || !isRowInView(toRow)) return;
    flight = { from: rectFor(fromRow), to: rectFor(toRow), tint };
    setSelectionTravelTarget(next);
    ownTravelTarget = next;
    // Landing: reveal the row's own highlight just before arrival so it fades in UNDER the
    // ghost (background transitions in var(--transition-fast)), then unmount the ghost once
    // the row is fully lit, for a dip-free handoff.
    flightTimeout = setTimeout(() => {
      releaseTravelTarget();
      flightTimeout = setTimeout(() => {
        flightTimeout = null;
        flight = null;
      }, 160);
    }, Math.max(0, MOTION.selectionMs - 40));
  }

  // Only an activeTabId change (or the container binding) launches a flight; everything
  // else (tint updates, tab patches) is read untracked so it can't cancel one mid-air.
  $effect(() => {
    const next = activeTabId;
    void container;
    const prev = previousActiveTabId;
    previousActiveTabId = next;
    untrack(() => handleActivation(next, prev));
  });

  onDestroy(endFlight);

  function styleFor(rect: IndicatorRect, flightTint: string): string {
    return `transform: translate(${rect.left}px, ${rect.top}px); width: ${rect.width}px; height: ${rect.height}px;${flightTint ? ` --tab-tint: ${flightTint};` : ""} transition-duration: ${MOTION.selectionMs}ms;`;
  }

  function flyTo(node: HTMLElement, params: { to: IndicatorRect }) {
    node.getBoundingClientRect(); // commit the starting rect so the transition has a from
    node.style.transform = `translate(${params.to.left}px, ${params.to.top}px)`;
    node.style.width = `${params.to.width}px`;
    node.style.height = `${params.to.height}px`;
  }
</script>

{#if flight}
  {#key flight}
    <div
      class="selection-ghost"
      style={styleFor(flight.from, flight.tint)}
      use:flyTo={{ to: flight.to }}
      aria-hidden="true"
    ></div>
  {/key}
{/if}

<style>
  .selection-ghost {
    position: absolute;
    top: 0;
    left: 0;
    z-index: 0;
    pointer-events: none;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--tab-tint, var(--accent)) 18%, var(--bg-selected));
    transition-property: transform, width, height;
    transition-timing-function: var(--motion-ease-spring);
    /* transition-duration is set inline from MOTION.selectionMs so the CSS flight and the
       JS landing timeout share one source. */
  }
</style>
