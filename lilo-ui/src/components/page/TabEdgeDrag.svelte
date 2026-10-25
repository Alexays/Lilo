<script lang="ts">
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import type { TabPosition } from "../../lib/bridge";
  import { t } from "../../lib/i18n/state.svelte";
  import { getTabEdgeTarget } from "../../stores/tabEdgeDrag.svelte";
  import { getTabPosition } from "../../stores/tabLayout.svelte";

  const EDGES: TabPosition[] = ["left", "right", "top", "bottom"];
  const target = $derived(getTabEdgeTarget());
</script>

<!-- While the tabs are lifted: a mark on every free edge, the aimed one filled at the tabs' final size. -->
<div class="tab-edge-drag" use:reportInteractiveZone={{ id: "tab-edge-drag" }} aria-hidden="true">
  {#each EDGES.filter((edge) => edge !== getTabPosition()) as edge (edge)}
    <span class="mark {edge}"></span>
    {#if edge === target}
      <span class="slot {edge}"></span>
    {/if}
  {/each}
</div>
<div class="hud" role="status">
  {target ? t(`tabEdgeDrag.${target}`) : t("tabEdgeDrag.pick")}
</div>

<style>
  .tab-edge-drag {
    position: fixed;
    inset: 0;
    z-index: 70;
    pointer-events: none;
  }

  .mark {
    position: absolute;
    border-radius: var(--radius-2xs);
    background: color-mix(in srgb, var(--text-secondary) 45%, transparent);
  }

  .mark.left,
  .mark.right {
    top: calc(50% - 40px);
    width: 5px;
    height: 80px;
  }

  .mark.left { left: 4px; }
  .mark.right { right: 4px; }

  .mark.top,
  .mark.bottom {
    left: calc(50% - 40px);
    width: 80px;
    height: 5px;
  }

  .mark.top { top: 4px; }
  .mark.bottom { bottom: 4px; }

  .slot {
    position: absolute;
    border-radius: var(--radius-lg);
    background: var(--accent-tint-14);
    box-shadow: inset 0 0 0 1.5px var(--accent);
    animation: slot-in 180ms var(--motion-ease-spring) both;
  }

  .slot.left { left: 8px; top: 8px; bottom: 8px; width: var(--sidebar-width); }
  .slot.right { right: 8px; top: 8px; bottom: 8px; width: var(--sidebar-width); }
  .slot.top { left: 8px; right: 8px; top: 4px; height: calc(var(--top-strip-height) - 8px); }
  .slot.bottom { left: var(--bottom-dock-margin); right: var(--bottom-dock-margin); bottom: var(--bottom-dock-margin); height: var(--bottom-dock-height); border-radius: var(--radius-xl); }

  .hud {
    position: fixed;
    top: 14px;
    left: 50%;
    transform: translateX(-50%);
    z-index: 71;
    padding: 7px 16px;
    border-radius: var(--radius-chip);
    /* Inverted, like a system HUD. */
    background: var(--text-primary);
    color: var(--bg-primary);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    white-space: nowrap;
    pointer-events: none;
    box-shadow: var(--shadow-md);
  }

  @keyframes slot-in {
    from { opacity: 0; }
  }

  @media (prefers-reduced-motion: reduce) {
    .slot { animation: none; }
  }
</style>
