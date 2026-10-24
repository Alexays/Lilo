<script lang="ts">
  import { sidebarActions } from "../../lib/bridge/actions";
  import { dndZone } from "../../lib/dndEngine/action";
  import type { DndActiveDrag } from "../../lib/dndEngine/store.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { getRootItems } from "../../stores/folders.svelte";
  import {
    commitSidebarDrop,
    getSidebarDrag,
    resetSidebarDrag,
    type SidebarZoneRef,
  } from "../../stores/sidebarDnd.svelte";
  import { getBookmarkedTabs } from "../../stores/tabs.svelte";

  // Drop targets for an empty bookmarks or pinned section, laid over the space header while a
  // drag runs. Growing those sections in the list instead would push every row down under the
  // pointer at pick-up, and the drop would land somewhere other than where it was aimed.
  let { spaceId }: { spaceId: string } = $props();

  const drag = $derived(getSidebarDrag());
  const showBookmark = $derived(drag?.kind === "tab" && getBookmarkedTabs(spaceId).length === 0);
  const showPin = $derived(drag !== null && getRootItems(spaceId, true).length === 0);

  const bookmarkZone: SidebarZoneRef = $derived({ id: `dock-bookmarked-${spaceId}`, section: "bookmarked", parentFolderId: null });
  const pinZone: SidebarZoneRef = $derived({ id: `dock-pinned-${spaceId}`, section: "pinned", parentFolderId: null });

  function drop(zone: SidebarZoneRef, activeDrag: DndActiveDrag): void {
    commitSidebarDrop(zone, [], sidebarActions.commitDrop, activeDrag);
  }
</script>

<div class="drop-dock" class:visible={showBookmark || showPin} aria-hidden="true">
  {#if showBookmark}
    <div
      class="dock-target bookmark"
      class:targeted={drag?.target?.id === bookmarkZone.id}
      use:dndZone={{
        id: bookmarkZone.id,
        axis: "horizontal",
        meta: { section: "bookmarked", spaceId, parentFolderId: null, compactPreview: true },
        canResolve: (context) => context.dragSource.kind === "tab",
        onDrop: (activeDrag) => drop(bookmarkZone, activeDrag),
        onCancel: resetSidebarDrag,
      }}
    >
      <svg class="dock-icon" viewBox="0 0 16 16" aria-hidden="true">
        <path d="M4.5 2.5h7a.5.5 0 0 1 .5.5v10.2a.3.3 0 0 1-.46.25L8 11.2l-3.54 2.25a.3.3 0 0 1-.46-.25V3a.5.5 0 0 1 .5-.5Z" />
      </svg>
      <span>{t("bookmarks.dropToBookmark")}</span>
    </div>
  {/if}
  {#if showPin}
    <div
      class="dock-target pin"
      class:targeted={drag?.target?.id === pinZone.id}
      use:dndZone={{
        id: pinZone.id,
        axis: "horizontal",
        meta: { section: "pinned", spaceId, parentFolderId: null, compactPreview: true },
        onDrop: (activeDrag) => drop(pinZone, activeDrag),
        onCancel: resetSidebarDrag,
      }}
    >
      <svg class="dock-icon" viewBox="0 0 16 16" aria-hidden="true">
        <path d="M9.6 1.9 14.1 6.4a.6.6 0 0 1-.17.97l-2.05.94-1.86 1.86.3 2.7a.4.4 0 0 1-.68.33L7.2 10.76 3.7 14.3a.5.5 0 0 1-.7-.7l3.54-3.5-2.44-2.44a.4.4 0 0 1 .33-.68l2.7.3 1.86-1.86.94-2.05a.6.6 0 0 1 .97-.17Z" />
      </svg>
      <span>{t("tabSection.dropToPin")}</span>
    </div>
  {/if}
</div>

<style>
  .drop-dock {
    position: absolute;
    inset: 0 var(--sidebar-right-pad, 10px) 0 10px;
    display: flex;
    align-items: center;
    gap: 6px;
    pointer-events: none;
    z-index: 3;
  }

  /* Pills pop in one after the other on the spring; they only mount while a drag runs. */
  .dock-target {
    animation: dock-pop 340ms var(--motion-ease-bounce) both;
  }

  .dock-target.pin {
    animation-delay: 45ms;
  }

  @keyframes dock-pop {
    from {
      opacity: 0;
      transform: translateY(-4px) scale(0.92);
    }
  }

  .dock-target {
    --dock-color: var(--color-bookmark);
    flex: 1 1 0;
    min-width: 0;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    border-radius: var(--radius-md);
    border: 1px dashed color-mix(in srgb, var(--dock-color) 45%, transparent);
    /* Opaque over the sidebar so the space name underneath never shows through. */
    background: color-mix(in srgb, var(--dock-color) 10%, var(--sidebar-bg));
    color: color-mix(in srgb, var(--dock-color) 80%, var(--text-primary));
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-medium);
    white-space: nowrap;
    overflow: hidden;
    transition:
      background var(--motion-duration-normal) var(--motion-ease-organic),
      border-color var(--motion-duration-normal) var(--motion-ease-organic),
      scale 320ms var(--motion-ease-bounce);
  }

  .dock-target.pin {
    --dock-color: var(--color-pin);
  }

  .dock-target.targeted {
    border-style: solid;
    border-color: color-mix(in srgb, var(--dock-color) 75%, transparent);
    background: color-mix(in srgb, var(--dock-color) 24%, var(--sidebar-bg));
    scale: 1.04;
  }

  .dock-target span {
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .dock-icon {
    flex-shrink: 0;
    width: 13px;
    height: 13px;
    fill: currentColor;
  }

  @media (prefers-reduced-motion: reduce) {
    .dock-target {
      animation: none;
      transition: none;
    }
  }
</style>
