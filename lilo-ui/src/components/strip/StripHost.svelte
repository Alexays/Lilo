<script lang="ts">
  import TabStrip from "./TabStrip.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { hasActivePanel, isDesignSystemShellOpen, isSettingsShellOpen } from "../../stores/panels.svelte";
  import { getTabPosition } from "../../stores/tabLayout.svelte";
  import { isSidebarOverlay, isSidebarShown } from "../../stores/ui.svelte";

  let { onenter, onleave }: { onenter: () => void; onleave: () => void } = $props();

  const isPanelOpen = $derived(hasActivePanel() || isSettingsShellOpen() || isDesignSystemShellOpen());
  // Latched like the sidebar's: the panels chunk loads on first open, then stays for close animations.
  let panelsLoaded = $state(false);
  $effect(() => {
    if (isPanelOpen) panelsLoaded = true;
  });

  // Overlays on the page (the Settings shell first) start past the floating column while it is open.
  $effect(() => {
    if (isPanelOpen) document.documentElement.dataset.stripPanelOpen = "";
    else delete document.documentElement.dataset.stripPanelOpen;
    return () => delete document.documentElement.dataset.stripPanelOpen;
  });
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="tab-strip-host tabs-surface"
  class:strip-hidden={!isSidebarShown()}
  class:strip-overlay={isSidebarOverlay()}
  use:reportInteractiveZone={{ id: "sidebar", active: isSidebarShown() }}
  onmouseenter={onenter}
  onmouseleave={onleave}
>
  <TabStrip edge={getTabPosition() === "bottom" ? "bottom" : "top"} />
</div>

<!-- A strip has no column for the panels: they float over the page's left edge. -->
{#if panelsLoaded}
  {#await import("../sidebar/SidebarPanels.svelte") then panels}
    <div
      class="strip-panels tabs-surface"
      class:open={isPanelOpen}
      inert={!isPanelOpen}
      use:reportInteractiveZone={{ id: "strip-panels", active: isPanelOpen }}
    >
      <panels.default active={isPanelOpen} />
    </div>
  {/await}
{/if}

<style>
  .strip-panels {
    position: fixed;
    left: var(--content-inset);
    top: calc(var(--chrome-content-top) + 4px);
    bottom: calc(var(--chrome-content-bottom) + 4px);
    width: var(--sidebar-width);
    overflow: hidden;
    border-radius: var(--float-radius-popover);
    background-color: var(--sidebar-bg);
    box-shadow: var(--chrome-overlay-shadow);
    pointer-events: auto;
    z-index: 45;
    transform: translateX(calc(-100% - 2 * var(--content-inset)));
    transition: transform 220ms var(--motion-ease-spring);
  }

  .strip-panels.open {
    transform: none;
  }

  @media (prefers-reduced-motion: reduce) {
    .strip-panels {
      transition: none;
    }
  }

  .tab-strip-host {
    position: fixed;
    left: 0;
    right: 0;
    top: 0;
    pointer-events: auto;
    background-color: var(--sidebar-bg);
    /* Over the command bar's page veil, like the page toolbar. */
    z-index: 61;
    transition:
      transform var(--motion-duration-slow) var(--motion-ease-standard),
      box-shadow var(--motion-duration-slow) ease,
      background-color var(--motion-duration-slow) var(--motion-ease-spring);
  }

  :global(html[data-tab-position='bottom']) .tab-strip-host {
    top: auto;
    bottom: var(--bottom-dock-margin);
    background-color: transparent;
  }

  .tab-strip-host.strip-hidden {
    transform: translateY(-100%);
    pointer-events: none;
  }

  :global(html[data-tab-position='bottom']) .tab-strip-host.strip-hidden {
    transform: translateY(calc(100% + var(--bottom-dock-margin)));
  }

  .tab-strip-host.strip-overlay {
    box-shadow: 0 4px 24px var(--sidebar-shadow);
    z-index: 50;
  }

  :global(html[data-tab-position='bottom']) .tab-strip-host.strip-overlay {
    box-shadow: none;
  }

  /* Lifted by a held press: the strip floats until dropped on an edge. */
  :global(html[data-tabs-lifting]) .tab-strip-host {
    transform: translate(var(--lift-x, 0px), var(--lift-y, 0px)) scale(0.96);
    transition: box-shadow var(--motion-duration-slow) ease;
    border-radius: var(--radius-lg);
    box-shadow: var(--chrome-overlay-shadow);
    z-index: 72;
  }
</style>
