<script lang="ts">
  import { flip } from "svelte/animate";
  import { cubicOut } from "svelte/easing";
  import { scale } from "svelte/transition";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { springEase } from "../../lib/motion/spring";
  import {
    dndItem,
    dndZone,
  } from "../../lib/dndEngine/action";
  import type { DndActiveDrag } from "../../lib/dndEngine/store.svelte";
  import { isPointInsideRect } from "../../lib/dndEngine/geometry";
  import type { DndTargetContext } from "../../lib/dndEngine/types";
  import SpaceMoveHint from "../spaces/SpaceMoveHint.svelte";
  import { getAgentClients, getAgentMood, getAgentsProfileId, isAgentsSpace, isHiddenAgentsSpace, isIsolatedAgentSpace } from "../../stores/agents.svelte";
  import { getProfileById, getProfiles } from "../../stores/profiles.svelte";
  import type { BridgeProfileSnapshot } from "../../lib/bridge/protocol";
  import { userProfiles } from "../settings/profilesModel";
  import { chromeActions, spaceActions, terminalActions } from "../../lib/bridge/actions";
  import { getTerminals } from "../../stores/keepAwake.svelte";
  import {
    clearPreviewTabMoveToSpace,
    isSpaceRecentlyDropped,
    queuePendingTabDrop,
    queuePendingSpaceDrop,
    setPreviewTabMoveToSpace,
  } from "../../stores/dropConfirmation.svelte";
  import {
    getActiveSpaceId,
    getFocusedSpaceId,
    getSpaces,
    type SpaceState,
  } from "../../stores/spaces.svelte";
  import {
    isDownloadsVisible,
    openAddEditor,
  } from "../../stores/panels.svelte";
  import { getSpacePagerVirtualIndex, spaceTracingEnabled, switchSpaceAnimated } from "../../stores/pager.svelte";
  import {
    getSidebarDrag,
    isSidebarDragActive,
  } from "../../stores/sidebarDnd.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    aggregateDownloadProgress,
    getDownloads,
    getUnseenDownloads,
    hasSessionDownloads,
    isActiveDownload,
    markDownloadsSeen,
  } from "../../stores/downloads.svelte";
  import { isDownloadUiEnabled } from "../../stores/extensions.svelte";
  import { getRecentArchivedTabs } from "../../stores/archivedTabs.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import {
    dndItemsForSpaces,
    flipDurationForSpaceDndItem,
    projectSpaceItemsWithShadow,
    spaceDndKey,
    spaceMoveIndexFromProjectedItems,
    type SpaceDndItem,
  } from "../../lib/dndEngine/adapters/spaces";
  import { isShadowItem } from "../../lib/dndEngine/projection";
  import { createFrameScheduler } from "../../lib/motion/frameScheduler";

  // AgentMascot at rest, as images the tooltip can show; an <img> cannot read --agents, so its value is inlined.
  const mascotIcon = (body: string) => `data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 22 22" fill="white" stroke="#795ceb" stroke-width="1.5">${body}<g fill="#795ceb" stroke="none"><ellipse cx="7" cy="10" rx="2" ry="2.5"/><ellipse cx="15" cy="10" rx="2" ry="2.5"/></g></svg>`,
  )}`;
  const agentMascotIcon = mascotIcon('<circle cx="11" cy="11" r="10.25"/>');
  const agentGhostIcon = mascotIcon('<path d="M3 10.5a8 8 0 0 1 16 0V20l-2.67-1.8-2.67 1.8-2.66-1.8-2.67 1.8-2.66-1.8L3 20Z" stroke-linejoin="round"/>');

  type SpaceDropMorphTarget = {
    spaceId: string;
    color: string;
    boxShadow: string;
  };

  type SidebarSpaceDropTarget = {
    itemId: string;
    spaceId: string;
    folder: boolean;
    morphTarget: SpaceDropMorphTarget | null;
  };

  const activeDownloads = $derived(getDownloads().filter(isActiveDownload));

  const activeDownloadCount = $derived(activeDownloads.length);

  const downloadProgress = $derived(aggregateDownloadProgress(activeDownloads));
  const unseenDownloads = $derived(getUnseenDownloads());

  const showDownloads = $derived(isDownloadUiEnabled() && (hasSessionDownloads() || activeDownloadCount > 0));
  const recentArchived = $derived(getRecentArchivedTabs());
  let slotButton: HTMLButtonElement | undefined = $state();
  let menuOpen = $state(false);

  $effect(() => {
    if (isDownloadsVisible() || (menuOpen && showDownloads)) markDownloadsSeen();
  });

  let spaceScrollerEl: HTMLDivElement | undefined = $state();
  // Which sides have tiles scrolled out of view, faded so the cut reads as "more this way".
  let fadeStart = $state(false);
  let fadeEnd = $state(false);
  $effect(() => {
    const el = spaceScrollerEl;
    if (!el) return;
    const update = () => {
      fadeStart = el.scrollLeft > 1;
      fadeEnd = el.scrollWidth - el.clientWidth - el.scrollLeft > 1;
    };
    el.addEventListener("scroll", update, { passive: true });
    const observer = new ResizeObserver(update);
    observer.observe(el);
    if (el.firstElementChild) observer.observe(el.firstElementChild);
    return () => {
      el.removeEventListener("scroll", update);
      observer.disconnect();
    };
  });
  // Tiles that scroll never open on a name (no room), so the active one's box is final: one glide brings it
  // in view, clear of the fades.
  // On the switch's target, so the bar glides along with the pages rather than after them.
  $effect(() => {
    const spaceId = getFocusedSpaceId();
    const el = spaceScrollerEl;
    if (!el || el.scrollWidth <= el.clientWidth) return;
    const tile = el.querySelector(`[data-space-dnd-id="${CSS.escape(spaceId)}"]`);
    if (!tile) return;
    // Not scrollIntoView: it would also scroll every ancestor, up to a page embedding the UI.
    const bar = el.getBoundingClientRect();
    const box = tile.getBoundingClientRect();
    const left = box.left - 18 < bar.left ? box.left - 18 - bar.left : box.right + 18 > bar.right ? box.right + 18 - bar.right : 0;
    if (left) el.scrollBy({ left, behavior: prefersReducedMotion() ? "instant" : "smooth" });
  });

  // What needs a look in the other Spaces, shown on their icons: a terminal waiting for an answer
  // outranks an acting agent. The shown Space's tabs say it already.
  const spaceActivity = $derived.by(() => {
    const states: Record<string, "attention" | "agent"> = {};
    for (const terminal of getTerminals()) {
      if (terminal.awaitingInputSince > 0) states[terminal.spaceId] = "attention";
    }
    for (const client of getAgentClients()) {
      if (client.busy) for (const id of client.spaceIds) if (states[id] !== "attention") states[id] = "agent";
    }
    delete states[getActiveSpaceId()];
    return states;
  });

  // With two user profiles or more, each Space says which one it is signed in with.
  const showsProfiles = $derived(userProfiles(getProfiles(), getAgentsProfileId()).length > 1);

  let suppressClickUntil = 0;
  let draggedSpaceId = $state<string | null>(null);
  let visualSpaceItems: SpaceDndItem[] | null = $state(null);
  let hoveredSidebarDropSpaceId = $state<string | null>(null);
  let sidebarSpaceDropTarget = $state<SidebarSpaceDropTarget | null>(null);
  let sidebarSpaceDropMorphTarget = $state<SpaceDropMorphTarget | null>(null);
  let recentlyAbsorbedSpaceId = $state<string | null>(null);

  const spaces = $derived(getSpaces());
  const reorderableSpaces = $derived(
    spaces.filter((space) => !space.isPrivate),
  );
  // Native keeps the Agents spaces last: with no agent and no tab, the bar leaves one out unless it is shown.
  const spaceBaseItems = $derived(
    dndItemsForSpaces(spaces).filter((item) => !isHiddenAgentsSpace(item.id) || item.id === getActiveSpaceId()),
  );
  const spaceZoneItems = $derived(visualSpaceItems ?? spaceBaseItems);
  const spacesById = $derived(new Map(spaces.map((space) => [space.id, space])));
  const hoveredSidebarDropSpace = $derived(
    hoveredSidebarDropSpaceId ? spacesById.get(hoveredSidebarDropSpaceId) : undefined,
  );
  const visualIndex = $derived(getSpacePagerVirtualIndex());
  const sidebarItemDragActive = $derived(isSidebarDragActive());
  const spaceReorderActive = $derived(draggedSpaceId !== null);
  const anySpaceDropGuideActive = $derived(spaceReorderActive || sidebarItemDragActive);

  function canReorder(space: SpaceState): boolean {
    return !space.isPrivate && !isAgentsSpace(space.id);
  }

  function handleSpaceClick(spaceId: string): void {
    if (Date.now() < suppressClickUntil) {
      return;
    }

    // A Space with a terminal waiting for an answer opens straight on it, the longest waiting first.
    const waiting = getTerminals()
      .filter((terminal) => terminal.spaceId === spaceId && terminal.awaitingInputSince > 0)
      .sort((a, b) => a.awaitingInputSince - b.awaitingInputSince)[0];
    if (waiting && spaceId !== getActiveSpaceId()) {
      terminalActions.reveal(waiting.tabId);
      return;
    }
    switchSpaceAnimated(spaceId);
  }

  function handleSpaceKeydown(event: KeyboardEvent, spaceId: string): void {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    handleSpaceClick(spaceId);
  }

  function showNativeSidebarContextMenu(event: MouseEvent, spaceId?: string): void {
    event.preventDefault();
    event.stopPropagation();
    chromeActions.showSidebarContextMenu({
      x: event.clientX,
      y: event.clientY,
      width: 1,
      height: 1,
      ...(spaceId ? { spaceId } : {}),
    });
  }

  function spaceDndOrder(items: SpaceDndItem[] | null): string {
    return items
      ?.map((item, index) => {
        const flags = [
          item.isPrivate ? "private" : "",
          isShadowItem(item) ? "shadow" : "",
        ].filter(Boolean).join(":");
        return `${index}:${item.id.slice(0, 8)}${flags ? `:${flags}` : ""}`;
      })
      .join(",") ?? "";
  }

  function traceSpaceDnd(
    eventName: "consider" | "finalize",
    drag: DndActiveDrag,
    items: SpaceDndItem[],
  ): void {
    if (!spaceTracingEnabled) return;
    chromeActions.traceSpaceDnd({
      stage: "ui",
      event: eventName,
      id: drag.source.item.id,
      trigger: eventName === "consider" ? "dragMoved" : "droppedIntoZone",
      source: "pointer",
      shadowIndex: items.findIndex(isShadowItem),
      baseOrder: spaceDndOrder(spaceBaseItems),
      itemsOrder: spaceDndOrder(items),
      visualOrder: spaceDndOrder(visualSpaceItems),
    });
  }

  function traceSpaceDndPointerProbe(event: MouseEvent): void {
    if (!spaceTracingEnabled) return;
    const target = event.target instanceof Element
      ? event.target.closest<HTMLElement>("[data-space-dnd-id]")
      : null;
    chromeActions.traceSpaceDnd({
      stage: "ui-probe",
      event: "mousedown",
      id: target?.dataset.spaceDndId ?? "",
      trigger: "capture",
      source: "pointer",
      shadowIndex: -1,
      baseOrder: spaceDndOrder(spaceBaseItems),
      itemsOrder: "",
      visualOrder: spaceDndOrder(visualSpaceItems),
    });
  }

  function handleSpaceDragMove(drag: DndActiveDrag): void {
    if (drag.source.item.kind !== "space" || drag.source.item.isPrivate) return;
    if (drag.target?.zoneId !== "bottom-bar-spaces") return;

    suppressClickUntil = Date.now() + 160;
    draggedSpaceId = drag.source.item.id;
    visualSpaceItems = projectSpaceItemsWithShadow(
      spaceBaseItems,
      drag.source.item.id,
      drag.target.index,
    );
    traceSpaceDnd("consider", drag, visualSpaceItems);
  }

  function handleSpaceDrop(drag: DndActiveDrag): void {
    const finalItems = visualSpaceItems;
    if (finalItems) {
      traceSpaceDnd("finalize", drag, finalItems);
    }
    const draggedId = drag.source.item.id;
    const toIndex = finalItems ? spaceMoveIndexFromProjectedItems({
      draggedId,
      previousItems: spaceBaseItems,
      nextItems: finalItems,
    }) : null;
    draggedSpaceId = null;
    visualSpaceItems = null;
    if (toIndex === null || !reorderableSpaces.some((space) => space.id === draggedId)) {
      return;
    }
    suppressClickUntil = Date.now() + 160;
    queuePendingSpaceDrop(draggedId, reorderableSpaces);
    spaceActions.move(draggedId, toIndex);
  }

  function handleSpaceCancel(): void {
    draggedSpaceId = null;
    visualSpaceItems = null;
  }

  // A sidebar row only targets the bar over a space icon: that is exactly where the window
  // drop moves it cross-space, so the sidebar zones never commit the same gesture too.
  function canResolveSpaceZone(context: DndTargetContext): boolean {
    if (context.dragSource.kind === "space") return true;
    if (context.dragSource.kind === "layer") return false;
    return context.zone.items.some((item) => isPointInsideRect(context.point, item.rect));
  }

  function commitSidebarDropToSpace(target: SidebarSpaceDropTarget): void {
    suppressClickUntil = Date.now() + 220;
    hoveredSidebarDropSpaceId = target.spaceId;
    recentlyAbsorbedSpaceId = target.spaceId;
    sidebarSpaceDropTarget = null;
    sidebarSpaceDropMorphTarget = target.morphTarget;
    window.setTimeout(() => {
      if (recentlyAbsorbedSpaceId === target.spaceId) recentlyAbsorbedSpaceId = null;
    }, 520);
    if (target.folder) {
      spaceActions.moveFolderToSpace(target.itemId, target.spaceId);
      return;
    }
    queuePendingTabDrop({
      tabId: target.itemId,
      kind: "move-space",
      targetSpaceId: target.spaceId,
    });
    setPreviewTabMoveToSpace(target.itemId, target.spaceId);
    spaceActions.moveTabToSpace(target.itemId, target.spaceId);
  }

  function spaceIdAt(x: number, y: number): string | null {
    for (const element of document.elementsFromPoint(x, y)) {
      const spaceId = element.closest<HTMLElement>("[data-space-dnd-id]")?.dataset.spaceDndId;
      if (spaceId) return spaceId;
    }
    return null;
  }

  function handleSidebarItemWindowDrop(event: PointerEvent): void {
    // A release within the move's frame would otherwise read a stale drop target.
    if (sidebarMoveFrame.cancel()) processSidebarItemWindowMove();
    const spaceId = spaceIdAt(event.clientX, event.clientY);
    const target = sidebarSpaceDropTarget;
    if (!spaceId || !target || target.spaceId !== spaceId) return;
    commitSidebarDropToSpace(target);
  }

  // elementsFromPoint per pointermove is too hot to run raw: coalesce to one
  // hit test per frame off the latest event.
  const sidebarMoveFrame = createFrameScheduler();
  let lastSidebarMoveEvent: PointerEvent | null = null;

  function handleSidebarItemWindowMove(event: PointerEvent): void {
    lastSidebarMoveEvent = event;
    sidebarMoveFrame.schedule(processSidebarItemWindowMove);
  }

  function processSidebarItemWindowMove(): void {
    const event = lastSidebarMoveEvent;
    if (!event) return;
    const drag = getSidebarDrag();
    if (!drag) return;
    const folder = drag.kind === "folder";

    const hitSpaceId = spaceIdAt(event.clientX, event.clientY);
    // The row already lives in the current space: its icon is not a move target.
    const spaceId = hitSpaceId === getActiveSpaceId() ? null : hitSpaceId;
    hoveredSidebarDropSpaceId = spaceId;
    if (spaceId) {
      const space = spacesById.get(spaceId);
      const morphTarget = space
        ? {
          spaceId,
          color: space.color,
          boxShadow: `0 10px 24px color-mix(in srgb, ${space.color} 28%, transparent)`,
        }
        : null;
      sidebarSpaceDropTarget = {
        itemId: drag.itemId,
        spaceId,
        folder,
        morphTarget,
      };
      sidebarSpaceDropMorphTarget = morphTarget;
      if (!folder) {
        setPreviewTabMoveToSpace(drag.itemId, spaceId);
      }
    } else {
      sidebarSpaceDropTarget = null;
      sidebarSpaceDropMorphTarget = null;
      clearPreviewTabMoveToSpace(drag.itemId);
    }
  }

  $effect(() => {
    if (!sidebarItemDragActive) return;

    window.addEventListener("pointermove", handleSidebarItemWindowMove, true);
    window.addEventListener("pointerup", handleSidebarItemWindowDrop, true);
    return () => {
      sidebarMoveFrame.cancel();
      lastSidebarMoveEvent = null;
      hoveredSidebarDropSpaceId = null;
      sidebarSpaceDropTarget = null;
      sidebarSpaceDropMorphTarget = null;
      clearPreviewTabMoveToSpace();
      window.removeEventListener("pointermove", handleSidebarItemWindowMove, true);
      window.removeEventListener("pointerup", handleSidebarItemWindowDrop, true);
    };
  });

  function getIconStyle(index: number): string {
    const proximity = Math.max(0, 1 - Math.abs(index - visualIndex));
    // Inactive tiles stay legible (emoji recognizable); the active one stands out by its highlight.
    const opacity = 0.7 + proximity * 0.3;
    const activeOpacity = proximity;
    const hoverOpacity = (1 - proximity) * 0.72;

    return `opacity: ${opacity.toFixed(3)}; --space-icon-active-opacity: ${activeOpacity.toFixed(3)}; --space-icon-hover-opacity: ${hoverOpacity.toFixed(3)};`;
  }

  // Natural width of each Space's name, capped to the room the bar leaves; the active tile opens to fit it.
  let labelWidths: Record<string, number> = $state({});
  let iconsWrapWidth = $state(0);
  // The tiles, the name's padding and the bar's own inset come off; too little left and the tile stays an icon.
  const labelRoom = $derived.by(() => {
    const room = Math.min(96, iconsWrapWidth - spaceZoneItems.length * 39 - 16);
    return room < 32 ? 0 : room;
  });

  function getLabelStyle(index: number, spaceId: string): string {
    const proximity = Math.max(0, 1 - Math.abs(index - visualIndex));
    if (proximity === 0 || labelRoom === 0) return "width: 0; opacity: 0;";
    // The name fades in late and out early, so a half-open tile never shows half a word.
    const shown = proximity * proximity;
    return `width: ${(((labelWidths[spaceId] ?? 0) + 8) * proximity).toFixed(2)}px; opacity: ${shown.toFixed(3)}; --label-shift: ${((1 - proximity) * -6).toFixed(2)}px;`;
  }
</script>

{#snippet spaceIconButton(space: SpaceState, index: number, profile: BridgeProfileSnapshot | undefined)}
  <div
    class="space-icon-btn"
    class:dragging={space.id === draggedSpaceId}
    class:recent-drop={isSpaceRecentlyDropped(space.id)}
    use:tooltip={{
      text: profile && profile.name !== space.name ? t("bottomBar.signedInAs", { space: space.name, profile: profile.name }) : space.name,
      iconSrc: isAgentsSpace(space.id) ? agentMascotIcon : isIsolatedAgentSpace(space.id) ? agentGhostIcon : undefined,
      iconText: space.icon || "🌐",
      // The menu bar's Spaces shortcuts count the same Spaces, in the same order.
      shortcut: index < 9 ? shortcutKeys(`space.select${index + 1}`) : undefined,
      disabled: sidebarItemDragActive,
    }}
    role="button"
    tabindex="0"
    aria-label={space.name}
    style={getIconStyle(index)}
    onclick={() => handleSpaceClick(space.id)}
    oncontextmenu={(event) => showNativeSidebarContextMenu(event, space.id)}
    onkeydown={(event) => handleSpaceKeydown(event, space.id)}
  >
    <span class="space-glyph" data-onboarding-anchor={space.id === getActiveSpaceId() ? "space-icon" : undefined}>
      {#if isAgentsSpace(space.id) || isIsolatedAgentSpace(space.id)}
        <!-- Loaded on demand: the tile shows only once an agent connects, so the first frame goes without. -->
        {#await import("./AgentMascot.svelte") then { default: AgentMascot }}
          <AgentMascot mood={getAgentMood(space.id)} ghost={isIsolatedAgentSpace(space.id)} />
        {/await}
      {:else}
        {space.icon || "🌐"}
      {/if}
    </span>
    <!-- Opens with the pager's own position, so the name follows a swipe frame by frame. -->
    <span class="space-label" style={getLabelStyle(index, space.id)} aria-hidden="true">
      <span class="space-label-text" bind:clientWidth={labelWidths[space.id]}>{space.name}</span>
    </span>
  </div>
{/snippet}

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="bottom-bar" oncontextmenu={showNativeSidebarContextMenu}>
  <!-- Two slots one button wide frame the tiles: the left one (downloads and archived tabs) stays reserved when empty,
       so the tiles stay centered and never shift as it comes and goes. -->
  <div class="bottom-side">
    {#if showDownloads || recentArchived.length > 0}
      <div class="download-btn-wrap">
        <button
          bind:this={slotButton}
          class="bottom-btn"
          class:active-indicator={isDownloadsVisible()}
          use:tooltip={t("bottomBar.library")}
          aria-label={activeDownloadCount > 0
            ? t("bottomBar.downloadsActiveCount", { count: activeDownloadCount })
            : t("bottomBar.library")}
          aria-expanded={menuOpen}
          onclick={() => (menuOpen = !menuOpen)}
        >
          {#if activeDownloadCount > 0}
            <!-- Static between progress ticks: a looping fill would keep WebKit's display link up. -->
            <span
              class="download-fill"
              style={`transform: scaleY(${downloadProgress >= 0 ? downloadProgress : 0.25})`}
              aria-hidden="true"
            ></span>
          {/if}
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M8 1.75v6.5M5.5 5.75 8 8.25l2.5-2.5" />
            <path d="M1.75 9.5h3.1l.9 1.75h4.5l.9-1.75h3.1M1.75 9.5v2.75a2 2 0 0 0 2 2h8.5a2 2 0 0 0 2-2V9.5" />
          </svg>
        </button>
        {#if unseenDownloads}
          <span class="download-dot" class:failed={unseenDownloads === "failed"} aria-hidden="true"></span>
        {/if}
        <!-- Loaded on first open: the menu costs the chrome's first frame nothing. -->
        {#if menuOpen && slotButton}
          {#await import("./ArchivedTabsMenu.svelte") then menu}
            <menu.default
              anchor={slotButton}
              label={t("bottomBar.library")}
              tabs={recentArchived}
              downloads={showDownloads ? getDownloads() : null}
              onclose={() => (menuOpen = false)}
            />
          {/await}
        {/if}
      </div>
    {/if}
  </div>

  <div
    class="space-icons-wrap"
    style:--label-room="{labelRoom}px"
    bind:clientWidth={iconsWrapWidth}
  >
    <SpaceMoveHint
      active={sidebarItemDragActive}
      targetName={hoveredSidebarDropSpace?.name}
      accentColor={hoveredSidebarDropSpace?.color}
    />
    <div
      class="space-icons-scroller"
      class:fade-start={fadeStart}
      class:fade-end={fadeEnd}
      bind:this={spaceScrollerEl}
    >
      <div
        class="space-icons"
        class:drag-active={anySpaceDropGuideActive}
        class:space-reorder-active={spaceReorderActive}
        role="group"
        aria-label={t("bottomBar.spaces")}
        onmousedowncapture={traceSpaceDndPointerProbe}
        use:dndZone={{
          id: "bottom-bar-spaces",
          axis: "horizontal",
          getItems: () => spaceZoneItems,
          canResolve: canResolveSpaceZone,
        }}
      >
        {#each spaceZoneItems as entry, index (spaceDndKey(entry))}
          {@const space = spacesById.get(entry.id)}
          <div
            animate:flip={{ duration: prefersReducedMotion() ? 0 : flipDurationForSpaceDndItem(entry), easing: springEase }}
            class="space-item-slot"
            role="presentation"
            data-space-dnd-id={space?.id ?? entry.id}
            data-is-dnd-shadow-item-hint={isShadowItem(entry)}
            use:dndItem={{
              item: entry,
              zoneId: "bottom-bar-spaces",
              disabled: isShadowItem(entry) || entry.isPrivate || isAgentsSpace(entry.id) || sidebarItemDragActive,
              onDragMove: handleSpaceDragMove,
              onDrop: handleSpaceDrop,
              onCancel: handleSpaceCancel,
            }}
          >
            {#if isShadowItem(entry)}
              <div class="space-dnd-placeholder" aria-hidden="true"></div>
            {:else if space}
              <!-- An Agents space shows its profile whenever it is one of the user's: they share its name. -->
              {@const profile = (showsProfiles || isAgentsSpace(space.id)) && !space.isPrivate && space.profileId !== getAgentsProfileId()
                ? getProfileById(space.profileId)
                : undefined}
              <div
                class="space-icon-slot"
                class:space-reorder-slot={anySpaceDropGuideActive && canReorder(space)}
                class:space-reorder-source={space.id === draggedSpaceId}
                class:space-drop-hover={space.id === hoveredSidebarDropSpaceId}
                class:space-drop-absorbing={space.id === recentlyAbsorbedSpaceId}
                role="presentation"
                data-dnd-space-drop-target={space.id === sidebarSpaceDropMorphTarget?.spaceId}
                style={space.id === sidebarSpaceDropMorphTarget?.spaceId
                  ? `--space-drop-target-color: ${sidebarSpaceDropMorphTarget.color}; --space-drop-target-shadow: ${sidebarSpaceDropMorphTarget.boxShadow};`
                  : ""}
              >
                <div
                  class="space-slot-drop-guide"
                  class:visible={sidebarItemDragActive && canReorder(space)}
                  aria-hidden="true"
                ></div>

                <div
                  class="space-drag-wrapper"
                  class:draggable-space={canReorder(space)}
                  class:tinted={!!profile}
                  style:--space-tint={profile?.color}
                  data-activity={spaceActivity[space.id]}
                  role="presentation"
                >
                  {@render spaceIconButton(space, index, profile)}
                </div>
                {#if spaceActivity[space.id] === "attention"}
                  <span
                    class="space-attention-dot"
                    aria-hidden="true"
                    in:scale={{ start: 0.2, duration: prefersReducedMotion() ? 0 : 260, easing: springEase }}
                    out:scale={{ start: 0.2, duration: prefersReducedMotion() ? 0 : 160, easing: cubicOut }}
                  ></span>
                {/if}
              </div>
            {/if}
          </div>
        {/each}
      </div>
    </div>
  </div>

  <div class="bottom-side end">
    <!-- Shown for good while it is the only way to learn Spaces exist; past one, the bar reveals it on hover. -->
    <button
      class="bottom-btn"
      class:reveal-on-hover={spaceBaseItems.length > 1}
      use:tooltip={t("bottomBar.newSpace")}
      aria-label={t("bottomBar.newSpace")}
      onclick={() => openAddEditor()}
    >
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <path
          d="M8 3v10M3 8h10"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
        />
      </svg>
    </button>
  </div>
</div>

<style>
  .bottom-bar {
    position: relative;
    z-index: 18;
    overflow: visible;
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px var(--sidebar-right-pad, 10px);
    flex-shrink: 0;
    contain: layout style;
  }

  .bottom-btn {
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
    transition:
      background var(--transition-fast),
      color var(--transition-fast),
      opacity var(--transition-fast);
  }

  .bottom-btn.reveal-on-hover {
    opacity: 0;
  }

  .bottom-bar:hover .bottom-btn.reveal-on-hover,
  .bottom-btn.reveal-on-hover:focus-visible {
    opacity: 1;
  }

  .bottom-side {
    flex: 0 0 28px;
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
  }

  .bottom-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .bottom-btn.active-indicator {
    color: var(--accent);
  }

  .download-btn-wrap {
    position: relative;
    width: 28px;
    height: 28px;
    flex-shrink: 0;
  }

  /* Rises behind the icon as the running downloads arrive. */
  .download-fill {
    position: absolute;
    inset: 0;
    background: color-mix(in srgb, var(--accent) 32%, transparent);
    transform-origin: bottom;
    pointer-events: none;
    transition: transform 0.3s ease;
  }

  .download-btn-wrap .bottom-btn {
    position: relative;
    overflow: hidden;
  }

  .download-btn-wrap .bottom-btn svg {
    position: relative;
  }

  @media (prefers-reduced-motion: reduce) {
    .download-fill {
      transition: none;
    }
  }

  /* Ended since the downloads were last looked at: blue when all went well, red when one failed. */
  .download-dot {
    position: absolute;
    top: 2px;
    right: 2px;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 0 1.5px var(--sidebar-bg);
    pointer-events: none;
  }

  .download-dot.failed {
    background: var(--danger);
  }

  .space-icons {
    display: flex;
    gap: 1px;
    align-items: center;
    justify-content: center;
    position: relative;
    overflow: visible;
    z-index: 24;
    width: fit-content;
    padding: 4px;
    border-radius: var(--radius-xl);
    isolation: isolate;
    transition:
      transform 180ms var(--motion-ease-spring);
  }

  .space-icons::before {
    content: "";
    position: absolute;
    inset: 0;
    z-index: -1;
    border-radius: inherit;
    background: color-mix(in srgb, var(--accent) 5%, transparent);
    box-shadow: inset 0 0 0 1px var(--accent-tint-10);
    opacity: 0;
    transform: scale(0.96);
    transform-origin: center;
    transition:
      opacity var(--motion-duration-normal) ease,
      transform 190ms var(--motion-ease-spring);
    pointer-events: none;
  }

  /* Not positioned: the move hint centers on the whole bar, not on the tiles. */
  .space-icons-wrap {
    display: flex;
    flex: 1 1 auto;
    align-items: center;
    justify-content: center;
    min-width: 0;
    overflow: visible;
  }

  /* Scrolls the tiles once they outgrow the bar; the block padding, cancelled by the margin, keeps
     the tiles' halos and drop shadows out of the clip. */
  .space-icons-scroller {
    min-width: 0;
    overflow-x: auto;
    overflow-y: hidden;
    padding-block: 8px;
    margin-block: -8px;
    scrollbar-width: none;
  }

  .space-icons-scroller::-webkit-scrollbar {
    display: none;
  }

  .space-icons-scroller.fade-start,
  .space-icons-scroller.fade-end {
    --fade-start: 0px;
    --fade-end: 0px;
    mask-image: linear-gradient(
      to right,
      transparent,
      black var(--fade-start),
      black calc(100% - var(--fade-end)),
      transparent
    );
  }

  .space-icons-scroller.fade-start {
    --fade-start: 18px;
  }

  .space-icons-scroller.fade-end {
    --fade-end: 18px;
  }

  .space-icons.drag-active::before {
    opacity: 1;
    transform: scale(1);
    animation: space-drop-zone-open 190ms var(--motion-ease-spring);
  }

  .space-icons.space-reorder-active {
    transform: translateY(-1px);
  }

  .space-icon-slot {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: none;
    min-width: 36px;
    /* The margin an icon tile has around it, kept by the open one so the tiles stay evenly spaced. */
    padding-inline: 4px;
    box-sizing: border-box;
    min-height: 36px;
  }

  .space-item-slot {
    display: flex;
    align-items: center;
    justify-content: center;
    flex: none;
    min-width: 38px;
    padding-inline: 1px;
    box-sizing: border-box;
    min-height: 36px;
    flex-shrink: 0;
    position: relative;
  }

  .space-dnd-placeholder {
    width: 38px;
    min-width: 38px;
    height: 36px;
    border-radius: var(--radius-md);
    box-sizing: border-box;
    border: 1px solid color-mix(in srgb, var(--accent) 42%, transparent);
    background:
      radial-gradient(
        circle at 50% 50%,
        var(--accent-tint-18) 0 34%,
        var(--accent-tint-8) 35% 100%
      );
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, white 8%, transparent),
      0 8px 18px var(--accent-tint-12);
    animation: space-dnd-placeholder-breathe 1.2s ease-in-out infinite;
  }

  /* Promote space slots to compositor layers only during reorder drag */
  .space-reorder-active .space-item-slot {
    will-change: transform;
  }

  .space-slot-drop-guide {
    position: absolute;
    inset: 4px;
    border-radius: var(--radius-md);
    background: var(--accent-tint-8);
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, var(--accent) 16%, transparent),
      0 6px 14px var(--accent-tint-8);
    opacity: 0;
    transform: scale(0.92);
    transition:
      opacity var(--motion-duration-fast) ease,
      transform 180ms var(--motion-ease-spring),
      background var(--motion-duration-fast) ease,
      box-shadow var(--motion-duration-fast) ease;
    pointer-events: none;
  }

  .space-slot-drop-guide.visible {
    opacity: 0.94;
    transform: scale(1);
  }

  .space-icon-slot.space-drop-hover .space-slot-drop-guide {
    opacity: 1;
    transform: scale(1.08);
    background: var(--accent-tint-14);
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, var(--accent) 32%, transparent),
      0 8px 18px var(--accent-tint-14);
  }

  .space-icon-slot.space-drop-hover .space-icon-btn {
    opacity: 1 !important;
    transform: translateY(-1px) scale(1.08);
  }

  .space-icon-slot.space-drop-absorbing .space-icon-btn {
    animation: space-drop-absorb 520ms var(--motion-ease-spring);
    box-shadow: var(--space-drop-target-shadow, 0 0 0 0 transparent);
  }

  .space-icon-slot.space-reorder-source .space-slot-drop-guide {
    opacity: 0.24;
    background: color-mix(in srgb, var(--text-primary) 6%, transparent);
    box-shadow: inset 0 0 0 1px
      var(--text-primary-tint-10);
  }

  .space-icon-slot:active {
    cursor: grabbing;
  }

  .space-drag-wrapper {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm);
    isolation: isolate;
  }

  /* The Space's profile, barely there at rest: on the wrapper, so the icon's opacity leaves it alone. */
  .space-drag-wrapper.tinted {
    background: color-mix(in srgb, var(--space-tint) 8%, transparent);
  }

  /* The active tile keeps the plain highlight, warmed by the profile rather than painted with it. */
  .tinted .space-icon-btn::before {
    background: color-mix(in srgb, var(--space-tint) 26%, var(--bg-active));
  }

  /* An acting agent glows behind the tile, never a line, so it never reads as the profile. Only
     opacity and transform animate, which stay on the compositor. */
  .space-drag-wrapper[data-activity="agent"]::before {
    content: "";
    position: absolute;
    inset: -6px;
    z-index: -1;
    border-radius: var(--radius-lg);
    background: radial-gradient(closest-side, color-mix(in srgb, var(--agents) 55%, transparent), transparent);
    pointer-events: none;
    animation: space-halo-breathe 1.8s ease-in-out infinite;
  }

  @media (prefers-reduced-motion: reduce) {
    .space-drag-wrapper[data-activity="agent"]::before {
      animation: none;
    }
  }

  @keyframes space-halo-breathe {
    0%, 100% {
      opacity: 1;
      transform: scale(1);
    }

    50% {
      opacity: 0.45;
      transform: scale(0.94);
    }
  }

  .space-icon-btn {
    min-width: 28px;
    height: 28px;
    border-radius: var(--radius-sm);
    border: none;
    background: none;
    cursor: pointer;
    padding: 0;
    font-size: var(--font-size-sm);
    line-height: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    opacity: 0.5;
    transition:
      opacity var(--motion-duration-normal) var(--motion-ease-spring),
      transform 180ms var(--motion-ease-spring);
    position: relative;
    overflow: hidden;
    isolation: isolate;
  }

  .space-glyph {
    flex: none;
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  /* Its width and opacity come from the pager each frame: no transition, or it would lag a swipe. */
  .space-label {
    position: relative;
    flex: none;
    height: 28px;
    overflow: hidden;
    pointer-events: none;
  }

  .space-label-text {
    position: absolute;
    left: 0;
    top: 50%;
    max-width: var(--label-room, 96px);
    transform: translate(var(--label-shift, 0), -50%);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    line-height: 16px;
  }

  .space-icon-btn::before,
  .space-icon-btn::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: inherit;
    pointer-events: none;
  }

  .space-icon-btn::before {
    background: var(--bg-active);
    opacity: var(--space-icon-active-opacity, 0);
    transition: opacity var(--motion-duration-normal) var(--motion-ease-spring);
    z-index: -1;
  }

  .space-icon-btn::after {
    background: var(--bg-hover);
    opacity: 0;
    transition: opacity var(--transition-fast);
    z-index: -1;
  }

  /* Promote space icon button layer only when actively hovered or dragged */
  .space-icon-btn:hover,
  .space-icon-btn:focus-visible {
    will-change: transform, opacity;
  }

  .space-icon-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
    opacity: 1;
  }

  .bottom-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .space-icon-btn:hover::after {
    opacity: var(--space-icon-hover-opacity, 0);
  }

  .space-drag-wrapper.draggable-space {
    cursor: grab;
    user-select: none;
  }

  .space-drag-wrapper.draggable-space:active {
    cursor: grabbing;
  }

  .space-icon-btn:active {
    cursor: grabbing;
  }

  .space-icon-btn.dragging {
    opacity: 0.22;
    transform: scale(0.9) rotate(-2deg);
    filter: saturate(0.8);
  }

  .space-icon-btn.recent-drop {
    animation: space-drop-arrive 760ms var(--motion-ease-spring);
  }

  @keyframes space-drop-arrive {
    0% {
      transform: scale(0.94);
      box-shadow: 0 0 0 0 color-mix(in srgb, var(--accent) 0%, transparent);
    }

    38% {
      transform: scale(1.06);
      box-shadow:
        0 0 0 1px var(--accent-tint-18),
        0 10px 18px var(--accent-tint-12);
    }

    100% {
      transform: scale(1);
      box-shadow: 0 0 0 0 color-mix(in srgb, var(--accent) 0%, transparent);
    }
  }

  @keyframes space-drop-absorb {
    0% {
      transform: scale(1);
      box-shadow: 0 0 0 0 color-mix(in srgb, var(--space-drop-target-color, var(--accent)) 0%, transparent);
    }

    42% {
      transform: scale(1.12);
      box-shadow: 0 0 0 8px color-mix(in srgb, var(--space-drop-target-color, var(--accent)) 22%, transparent);
    }

    100% {
      transform: scale(1);
      box-shadow: 0 0 0 0 color-mix(in srgb, var(--space-drop-target-color, var(--accent)) 0%, transparent);
    }
  }

  @keyframes space-drop-zone-open {
    from {
      opacity: 0;
      transform: scale(0.96);
    }

    to {
      opacity: 1;
      transform: scale(1);
    }
  }

  @keyframes space-dnd-placeholder-breathe {
    0%, 100% {
      opacity: 0.9;
      transform: scale(0.96);
    }

    50% {
      opacity: 1;
      transform: scale(1.03);
    }
  }


  /* The only dot in the bar: on the tile's top-right corner, ringed with the bar's background. */
  .space-attention-dot {
    position: absolute;
    top: 1px;
    right: 1px;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--sidebar-bg);
    pointer-events: none;
  }
</style>
