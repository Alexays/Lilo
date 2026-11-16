<script module lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  const emptyTitles = { favorites: "bookmarks.favorites", pinned: "tabSection.pinnedTabs", open: "tabSection.openTabs" };
  export { emptySection };
</script>

{#snippet emptySection(kind: "favorites" | "pinned" | "open")}
  <div class="sidebar-empty-slot" data-empty-section={kind}>
    <strong>{t(emptyTitles[kind])}</strong>
    <p>{t(`sidebar.emptySections.${kind}`)}</p>
  </div>
{/snippet}

<style>
  .sidebar-empty-slot {
    flex: none; margin: 4px var(--sidebar-right-pad, 8px) 6px 8px; padding: 8px;
    border: 1px dashed var(--sidebar-border); border-radius: var(--radius-md);
    pointer-events: none; color: var(--text-secondary); font-size: var(--font-size-xs); line-height: 1.4;
  }
  .sidebar-empty-slot strong { color: var(--text-primary); font-size: var(--font-size-sm); font-weight: var(--font-weight-medium); }
  .sidebar-empty-slot p { margin: 4px 0 0; }

</style>
