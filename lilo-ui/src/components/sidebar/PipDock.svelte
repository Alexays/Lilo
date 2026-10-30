<script lang="ts">
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { isPipDockActive, getPipDockTitle, getPipDockAspectRatio } from "../../stores/pipDock.svelte";
</script>

{#if isPipDockActive()}
  <div
    class="pip-dock"
    data-native-surface
    title={getPipDockTitle()}
    style:aspect-ratio={getPipDockAspectRatio()}
    use:reportInteractiveZone={{ id: "pip-dock" }}
  ></div>
{/if}

<style>
  /* Space reservation only: the native scaled web view paints over this slot, so it stays transparent. The side
     margins match the sidebar rows and are mirrored by TabDockController.horizontalInset. */
  .pip-dock {
    flex-shrink: 0;
    margin: 0 var(--sidebar-right-pad, 10px) 8px 10px;
  }
</style>
