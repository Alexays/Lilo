<script lang="ts">
  import { tooltipSide } from "../../stores/tabLayout.svelte";
  import { translateFlip } from "../../lib/motion/translateFlip";
  import { springEase } from "../../lib/motion/spring";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import TabLoader from "./TabLoader.svelte";
  import {
    dndItem,
    dndZone,
  } from "../../lib/dndEngine/action";
  import type { DndActiveDrag } from "../../lib/dndEngine/store.svelte";
  import { tabActions, sidebarActions } from "../../lib/bridge/actions";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import {
    getActiveTabId,
    getBookmarkedTabs,
    getTabsById,
  } from "../../stores/tabs.svelte";
  import { tooltip } from "../../lib/tooltip";
  import {
    startTabMemoryLiveRefresh,
    stopTabMemoryLiveRefresh,
    tabUsageLabel,
  } from "../../stores/tabMemory.svelte";
  import {
    clearTabPreview,
    getTabPreviewTabId,
    hoverTabPreview,
  } from "../../stores/tabPreview.svelte";
  import { subscribeHoverClear } from "../../lib/hoverClear";
  import { tooltipTabURL } from "../../lib/bridge/coerceHelpers";
  import {
    dndItemsForFolderTabs,
    flipDurationForSidebarDndItem,
    sidebarDndKey,
  } from "../../lib/dndEngine/adapters/sidebar";
  import { isShadowItem } from "../../lib/dndEngine/projection";
  import {
    commitSidebarDrop,
    getRecentlyDroppedId,
    getZoneItems,
    getSidebarDrag,
    isSidebarDragActive,
    resetSidebarDrag,
    type SidebarZoneRef,
  } from "../../stores/sidebarDnd.svelte";
  import { getPreviewTabMoveToSpace } from "../../stores/dropConfirmation.svelte";
  import { closeTabEditor, getEditingTab } from "../../stores/tabRename.svelte";
  import SavedTabEditor from "./SavedTabEditor.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { titleUnread, unreadBadgeText } from "../../lib/titleUnread";

  let {
    spaceId,
    interactive,
  }: {
    spaceId: string;
    interactive: boolean;
  } = $props();

  const bookmarks = $derived(getBookmarkedTabs(spaceId));
  // Precomputed per store write, and a superset of `bookmarks`, so there is no Map to rebuild here.
  const bookmarksById = $derived(getTabsById(spaceId));
  const dragActive = $derived(isSidebarDragActive());
  const isMovingToSpace = $derived(getPreviewTabMoveToSpace() !== null);
  // An empty strip stays collapsed during a drag: SidebarDropDock takes the drop instead, so
  // nothing below shifts under the pointer.
  const isVisible = $derived(bookmarks.length > 0);
  // Keyed on the ids: a bookmarked tab's runtime patch hands it a new snapshot, and a new item
  // array would re-run the animated each below, a FLIP measure of every tile.
  const bookmarkIdsKey = $derived(bookmarks.map((tab) => tab.id).join("\n"));
  const bookmarkBaseItems = $derived(
    dndItemsForFolderTabs(bookmarkIdsKey ? bookmarkIdsKey.split("\n").map((id) => ({ id })) : []),
  );
  const bookmarkZone: SidebarZoneRef = $derived({
    id: `bookmarked-tabs-${spaceId}`,
    section: "bookmarked",
    parentFolderId: null,
  });
  const bookmarkZoneItems = $derived(getZoneItems(bookmarkZone, bookmarkBaseItems));
  const bookmarkZoneIsEmpty = $derived(bookmarkZoneItems.length === 0);
  const activeTabId = $derived(getActiveTabId(spaceId));
  const recentlyDraggedId = $derived(getRecentlyDroppedId());
  const previewedTabId = $derived(getTabPreviewTabId());
  // Bookmarks for tabs that are still open carry a live memory estimate in their tooltip.
  // We live-refresh it only while a tile is hovered; the store ref-counts a shared timer.
  let hoveredBookmarkId: string | null = $state(null);
  // Drop the hover while dragging, when the window blurs, or when the tab is hidden;
  // otherwise a tile left "hovered" would keep the shared memory timer running.
  $effect(() => {
    if (dragActive && hoveredBookmarkId !== null) hoveredBookmarkId = null;
  });
  // Subscribes to the shared module-level listeners in lib/hoverClear instead of registering
  // its own window/document listeners per instance (see TabItem.svelte for the same pattern).
  $effect(() => {
    return subscribeHoverClear(() => {
      hoveredBookmarkId = null;
      clearTabPreview();
    });
  });
  // A tile removed under the pointer (closed, unbookmarked) never gets its mouseleave.
  $effect(() => {
    if (hoveredBookmarkId === null) return;
    if (bookmarks.some((tab) => tab.id === hoveredBookmarkId)) return;
    hoveredBookmarkId = null;
    clearTabPreview();
  });
  $effect(() => () => {
    if (hoveredBookmarkId !== null) clearTabPreview();
  });
  $effect(() => {
    if (hoveredBookmarkId === null) return;
    startTabMemoryLiveRefresh(hoveredBookmarkId);
    return stopTabMemoryLiveRefresh;
  });

  function handleBookmarkDrop(drag: DndActiveDrag): void {
    commitSidebarDrop(bookmarkZone, bookmarkBaseItems, sidebarActions.commitDrop, drag);
  }

  // Tooltip params rebuild on every shared hover/drag signal flip; caching the URL-derived
  // strings keeps those flips cheap instead of re-running new URL() for every tile.
  const bookmarkHostCache = new Map<string, string>();
  const bookmarkSubtitleCache = new Map<string, string>();

  function cachedURLString(
    cache: Map<string, string>,
    url: string | undefined,
    compute: (value: string) => string,
  ): string {
    const key = url ?? "";
    let value = cache.get(key);
    if (value === undefined) {
      value = compute(key);
      if (cache.size > 512) cache.clear();
      cache.set(key, value);
    }
    return value;
  }

  function bookmarkHost(bookmark: { url?: string }): string {
    return cachedURLString(bookmarkHostCache, bookmark.url, (value) => {
      try {
        return new URL(value).hostname.replace(/^www\./, "");
      } catch {
        return value;
      }
    });
  }

  function bookmarkSubtitle(url: string | undefined): string {
    return cachedURLString(bookmarkSubtitleCache, url, tooltipTabURL);
  }

  function bookmarkLabel(bookmark: { title?: string; customTitle?: string; url?: string }): string {
    return bookmark.customTitle || titleUnread(bookmark.title ?? "", true).title.trim() || bookmarkHost(bookmark);
  }

  // A sleeping bookmark keeps the title it had, so its count is stale; the open one is being read.
  function bookmarkUnread(bookmark: { id: string; title?: string; isClosed: boolean; hasUnreadNotification?: boolean }): string {
    if (bookmark.isClosed || bookmark.id === activeTabId) return "";
    const unread = titleUnread(bookmark.title ?? "", true);
    if (unread.count) return unreadBadgeText(unread.count);
    return unread.marked || bookmark.hasUnreadNotification ? "dot" : "";
  }

  // Only the hovered tile reads the memory estimate, so a process snapshot doesn't rebuild
  // every tile's tooltip params (see TabItem.svelte for the same gate).
  function bookmarkMemory(bookmark: { id: string }): string {
    if (hoveredBookmarkId !== bookmark.id) return "";
    return tabUsageLabel(bookmark.id);
  }

  // A tile has no room for its editor: it opens under the grid.
  const editing = $derived.by(() => {
    const edit = interactive ? getEditingTab() : null;
    const bookmark = edit ? bookmarks.find((tab) => tab.id === edit.id) : undefined;
    return edit && bookmark ? { bookmark, homeURL: edit.homeURL } : null;
  });

  $effect(() => {
    if (editing) clearTabPreview();
  });

  function openBookmark(bookmark: { id: string }): void {
    optimisticallyActivateTab(bookmark.id);
    tabActions.switchTo(bookmark.id);
  }

  function handleBookmarkTileKeydown(
    event: KeyboardEvent,
    bookmark: { id: string },
  ): void {
    if (event.defaultPrevented) return;
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    openBookmark(bookmark);
  }

  function handleBookmarkContextMenu(
    bookmark: { id: string },
    e: MouseEvent,
  ): void {
    e.preventDefault();
    e.stopPropagation();
    const el = e.currentTarget as HTMLElement;
    const rect = el.getBoundingClientRect();
    tabActions.showContextMenu(
      bookmark.id,
      rect.left,
      rect.top,
      rect.width,
      rect.height,
    );
  }

</script>

<div
  class="bookmarked-tabs"
  role="group"
  aria-label={t("bookmarks.groupLabel")}
>
  <div
    class="bookmarked-tabs-body"
    class:idle-empty={!isVisible}
  >
    <div
      class="bookmarked-list"
      class:drag-active={dragActive && isVisible}
      class:is-empty={bookmarkZoneIsEmpty}
      class:idle-empty={!isVisible}
      data-drop-label={t("bookmarks.dropToBookmark")}
      role="list"
      aria-hidden={!isVisible}
      use:dndZone={{
        id: bookmarkZone.id,
        axis: "grid",
        meta: { section: "bookmarked", spaceId, parentFolderId: null },
        getItems: () => bookmarkZoneItems,
        // Collapsed, the strip is a sliver on the section boundary: SidebarDropDock takes the drop.
        canResolve: (context) => isVisible && context.dragSource.kind === "tab",
        onDrop: handleBookmarkDrop,
        onCancel: resetSidebarDrag,
      }}
    >
      {#each bookmarkZoneItems as entry (sidebarDndKey(entry))}
        <div
          animate:translateFlip={{ duration: prefersReducedMotion() ? 0 : flipDurationForSidebarDndItem(entry, { recentlyDraggedId, itemCount: bookmarkZoneItems.length }), easing: springEase }}
          class="bookmark-slot"
          class:recent-drop={entry.id === recentlyDraggedId}
          data-is-dnd-shadow-item-hint={isShadowItem(entry)}
          role="presentation"
          use:dndItem={{
            item: entry,
            zoneId: bookmarkZone.id,
            disabled: isShadowItem(entry) || !interactive || isMovingToSpace,
            onCancel: resetSidebarDrag,
          }}
        >
          {#if isShadowItem(entry)}
            <div
              class="bookmark-placeholder"
              class:held={getSidebarDrag()?.intoCollapsedFolder}
              aria-hidden="true"
            ></div>
          {:else}
            {@const bookmark = bookmarksById.get(entry.id)}
            {#if bookmark}
              {@const unreadBadge = bookmarkUnread(bookmark)}
              <div role="presentation">
                <div
                  role="button"
                  tabindex={interactive ? 0 : -1}
                  class="bookmark-tile"
                  class:active={bookmark.id === activeTabId}
                  class:editing={bookmark.id === editing?.bookmark.id}
                  class:closed={bookmark.isClosed}
                  style={bookmark.faviconDominantColor
                    ? `--tab-glow: ${bookmark.faviconDominantColor}`
                    : undefined}
                  use:tooltip={{
                    text: bookmarkLabel(bookmark),
                    subtitle: bookmarkSubtitle(bookmark.url),
                    memory: bookmarkMemory(bookmark),
                    iconSrc: bookmark.faviconDataURL,
                    placement: tooltipSide(),
                    disabled: dragActive || previewedTabId === bookmark.id,
                  }}
                  aria-label={unreadBadge === "dot"
                    ? `${bookmarkLabel(bookmark)}, ${t("tabItem.unread")}`
                    : unreadBadge
                      ? `${bookmarkLabel(bookmark)}, ${t("tabItem.unreadCount", { count: unreadBadge })}`
                      : bookmarkLabel(bookmark)}
                  onclick={() => openBookmark(bookmark)}
                  onkeydown={(event) => handleBookmarkTileKeydown(event, bookmark)}
                  oncontextmenu={(e) => handleBookmarkContextMenu(bookmark, e)}
                  onmouseenter={(e) => {
                    if (dragActive) return;
                    hoveredBookmarkId = bookmark.id;
                    if (interactive) {
                      const rect = e.currentTarget.getBoundingClientRect();
                      hoverTabPreview(
                        {
                          id: bookmark.id,
                          title: bookmarkLabel(bookmark),
                          url: bookmark.url ?? "",
                          favicon: bookmark.faviconDataURL,
                        },
                        rect,
                      );
                    }
                  }}
                  onmouseleave={() => {
                    if (hoveredBookmarkId === bookmark.id) hoveredBookmarkId = null;
                    clearTabPreview();
                  }}
                >
                  <div class="bookmark-icon-inner">
                    {#if bookmark.isLoading}
                      <TabLoader />
                    {:else}
                      <SiteFavicon
                        src={bookmark.faviconDataURL}
                        title={bookmark.title}
                        url={bookmark.url}
                        size={18}
                        radius={5}
                        asleep={bookmark.isClosed}
                      />
                    {/if}
                  </div>
                  {#if unreadBadge === "dot"}
                    <span class="unread-dot" aria-hidden="true"></span>
                  {:else if unreadBadge}
                    <span class="unread-count" aria-hidden="true">{unreadBadge}</span>
                  {/if}
                </div>
              </div>
            {/if}
          {/if}
        </div>
      {/each}
    </div>
    {#if editing}
      <div class="bookmark-editor">
        <SavedTabEditor tab={editing.bookmark} homeURL={editing.homeURL} onclose={closeTabEditor} />
      </div>
    {/if}
  </div>
</div>

<style>
  .bookmarked-tabs {
    position: relative;
    flex-shrink: 0;
  }

  .bookmarked-tabs-body {
    padding: 4px var(--sidebar-right-pad, 10px) 4px 10px;
    box-sizing: border-box;
    transition: padding 150ms var(--motion-ease-spring);
  }

  .bookmarked-tabs-body.idle-empty {
    padding-top: 0;
    padding-bottom: 0;
  }

  .bookmarked-list {
    --bookmark-zone-color: var(--color-bookmark);
    position: relative;
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(34px, 1fr));
    gap: 6px;
    min-height: 0;
    /* The drop zone's border, cancelled by the margin so the tiles line up with the rows. */
    margin: -1px;
    border: 1px solid transparent;
    border-radius: var(--radius-md);
    box-sizing: border-box;
    outline: none;
    opacity: 1;
    transform: scaleY(1);
    transform-origin: top;
    transition:
      height 150ms var(--motion-ease-spring),
      min-height 150ms var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease,
      transform 150ms var(--motion-ease-spring),
      background var(--motion-duration-fast) ease,
      border-color var(--motion-duration-fast) ease;
  }

  .bookmarked-list.idle-empty {
    height: 0;
    min-height: 0;
    opacity: 0;
    transform: scaleY(0.92);
    overflow: hidden;
  }

  .bookmarked-list.drag-active.is-empty {
    height: 34px;
    min-height: 34px;
    overflow: hidden;
    border-color: color-mix(in srgb, var(--bookmark-zone-color) 36%, transparent);
    background: color-mix(in srgb, var(--bookmark-zone-color) 11%, transparent);
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, white 8%, transparent),
      0 6px 14px color-mix(in srgb, var(--bookmark-zone-color) 8%, transparent);
    animation: sidebar-dz-breathe 1.35s ease-in-out infinite;
    transform-origin: center;
    will-change: opacity, transform;
  }

  .bookmarked-list.drag-active.is-empty::before,
  .bookmarked-list.drag-active.is-empty::after {
    position: absolute;
    top: 50%;
    z-index: 1;
    opacity: 1;
    pointer-events: none;
  }

  .bookmarked-list.drag-active.is-empty::before {
    content: "";
    left: 50%;
    width: 13px;
    height: 14px;
    background: color-mix(in srgb, var(--bookmark-zone-color) 84%, var(--text-primary));
    -webkit-mask: url("data:image/svg+xml,%3Csvg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath fill='black' d='M6 3h10c.6 0 1 .4 1 1v7h-2V6H8v11.5l4-2.3 2.2 1.3 1-1.8L12 12.9l-6 3.4V4c0-.6.4-1 1-1zm13 8v3h3v2h-3v3h-2v-3h-3v-2h3v-3h2z'/%3E%3C/svg%3E") center / contain no-repeat;
    mask: url("data:image/svg+xml,%3Csvg viewBox='0 0 24 24' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath fill='black' d='M6 3h10c.6 0 1 .4 1 1v7h-2V6H8v11.5l4-2.3 2.2 1.3 1-1.8L12 12.9l-6 3.4V4c0-.6.4-1 1-1zm13 8v3h3v2h-3v3h-2v-3h-3v-2h3v-3h2z'/%3E%3C/svg%3E") center / contain no-repeat;
    transform: translate(-74px, -50%);
  }

  .bookmarked-list.drag-active.is-empty::after {
    content: attr(data-drop-label);
    left: 50%;
    color: color-mix(in srgb, var(--bookmark-zone-color) 82%, var(--text-primary));
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-medium);
    letter-spacing: 0;
    white-space: nowrap;
    transform: translate(-50px, -50%);
  }

  .bookmark-slot {
    position: relative;
    width: 100%;
  }

  .bookmark-placeholder.held {
    visibility: hidden;
  }

  .bookmark-placeholder {
    width: 100%;
    height: 34px;
    box-sizing: border-box;
    border: 1px solid color-mix(in srgb, var(--bookmark-zone-color) 42%, transparent);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--bookmark-zone-color) 12%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, white 8%, transparent);
    animation: sidebar-dz-placeholder-breathe 1.35s ease-in-out infinite;
    transform-origin: center;
    will-change: opacity, transform;
  }

  .bookmark-slot.recent-drop .bookmark-placeholder {
    animation: sidebar-dz-placeholder-absorb 230ms var(--motion-ease-spring);
  }

  .bookmark-tile {
    width: 100%;
    height: 34px;
    padding: 0;
    border: none;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--bg-hover) 88%, transparent);
    color: var(--text-primary);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    position: relative;
    min-width: 0;
  }

  .bookmark-tile:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .bookmark-tile:hover {
    background: color-mix(in srgb, var(--tab-glow, transparent) 5%, color-mix(in srgb, var(--bg-active) 88%, transparent));
    box-shadow:
      inset 0 0 0 1px var(--accent-tint-22),
      0 8px 16px color-mix(in srgb, var(--text-primary) 8%, transparent);
  }

  .bookmark-tile.active {
    --bookmark-active-bg: color-mix(in srgb, var(--tab-glow, transparent) 9%, color-mix(in srgb, var(--bg-active) 86%, transparent));
    background: var(--bookmark-active-bg);
    box-shadow:
      inset 0 0 0 1px color-mix(in srgb, var(--accent) 28%, transparent),
      0 0 0 1px
        color-mix(in srgb, var(--bookmark-active-bg) 54%, transparent),
      0 0 16px 0px
        color-mix(in srgb, var(--bookmark-active-bg) 72%, transparent);
  }

  .bookmark-icon-inner {
    position: absolute;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .unread-dot,
  .unread-count {
    position: absolute;
    top: 3px;
    right: 3px;
    background: var(--accent);
    box-shadow: 0 0 0 1.5px var(--sidebar-bg, var(--bg-primary));
  }

  .unread-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
  }

  .unread-count {
    min-width: 14px;
    height: 14px;
    padding: 0 4px;
    box-sizing: border-box;
    border-radius: var(--radius-chip);
    color: var(--accent-text);
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-semibold);
    font-variant-numeric: tabular-nums;
    font-feature-settings: "case";
    line-height: 14px;
    text-align: center;
  }

  .bookmark-editor {
    margin-top: 6px;
  }

  .bookmark-tile.editing {
    box-shadow: 0 0 0 2px var(--accent);
  }

  @media (prefers-reduced-motion: reduce) {
    .bookmarked-list.drag-active.is-empty,
    .bookmark-placeholder,
    .bookmark-slot.recent-drop .bookmark-placeholder {
      animation: none;
    }
  }
</style>
