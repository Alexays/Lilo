<script lang="ts">
  import TabStrip from "./TabStrip.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { dismissable } from "../../lib/actions/dismissable";
  import { closeEditor, editorState, getActivePanel, getPageShell, isDesignSystemShellOpen, isEditorOpen } from "../../stores/panels.svelte";
  import { getTabPosition } from "../../stores/tabLayout.svelte";
  import { isSidebarOverlay, isSidebarShown } from "../../stores/ui.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { pageBarStyle } from "../../lib/pageBarTheme";
  import { shellBarColor } from "../../stores/theme.svelte";

  let { accent, onenter, onleave }: { accent: string; onenter: () => void; onleave: () => void } = $props();

  // On top the strip takes the bar's color, as the page toolbar does; read apart from the tab, as there. The bottom
  // one sits on the window's surface: the page's bottom edge is whatever scrolls by.
  const onTop = $derived(getTabPosition() === "top");
  const pageColor = $derived(onTop ? shellBarColor() ?? getActiveTab()?.pageColor : undefined);
  // A system screen covers the page: the bottom strip paints the Space's own color.
  const coversPage = $derived(getPageShell() !== null && !onTop);
  const style = $derived(coversPage ? undefined : pageBarStyle(pageColor, accent));

  // System screens are not among them: in a strip each is a page of its own, its navigation inside. Nor is the Space
  // editor: it drops from the strip's Space button, over the page it repaints.
  const isPanelOpen = $derived((getActivePanel() !== null && !isEditorOpen()) || isDesignSystemShellOpen());
  // Latched like the sidebar's: the panels chunk loads on first open, then stays for close animations.
  let panelsLoaded = $state(false);
  $effect(() => {
    if (isPanelOpen) panelsLoaded = true;
  });

  // Overlays on the page (the Design System shell first) start past the floating column while it is open.
  $effect(() => {
    if (isPanelOpen) document.documentElement.dataset.stripPanelOpen = "";
    else delete document.documentElement.dataset.stripPanelOpen;
    return () => delete document.documentElement.dataset.stripPanelOpen;
  });

  // Under a top strip, over a bottom one, aligned on the Space button and clear of the page's bars; it scrolls when
  // the window is short.
  let viewport = $state({ width: window.innerWidth, height: window.innerHeight });
  const editorAt = $derived.by(() => {
    if (!isEditorOpen()) return null;
    void viewport;
    const chip = document.querySelector(".tab-strip-host .space-chip")?.getBoundingClientRect();
    const strip = document.querySelector(".tab-strip-host")?.getBoundingClientRect();
    if (!chip || !strip) return null;
    const left = Math.max(8, Math.min(chip.left, viewport.width - EDITOR_WIDTH - 8));
    return getTabPosition() === "bottom"
      ? { left, bottom: viewport.height - strip.top + 6, maxHeight: `calc(${strip.top - 12}px - var(--chrome-content-top))` }
      : { left, top: strip.bottom + 6, maxHeight: `calc(${viewport.height - strip.bottom - 12}px - var(--chrome-content-bottom))` };
  });
  const EDITOR_WIDTH = 320;
  // A Space being edited applies each change as it goes, so a press outside just closes it; a new one waits for
  // Create Space or Cancel.
  const dismissEditor = dismissable({ onDismiss: closeEditor, ignore: `[aria-expanded="true"], .ui-modal` });
</script>

<svelte:window onresize={() => (viewport = { width: window.innerWidth, height: window.innerHeight })} />

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="tab-strip-host tabs-surface"
  {style}
  class:strip-hidden={!isSidebarShown()}
  class:strip-overlay={isSidebarOverlay()}
  class:covers-page={coversPage}
  use:reportInteractiveZone={{ id: "tab-strip", active: isSidebarShown() }}
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

{#if editorAt}
  {#await import("../spaces/SpaceEditor.svelte") then editor}
    <div
      class="strip-editor tabs-surface"
      class:below={editorAt.top !== undefined}
      style:left="{editorAt.left}px"
      style:top={editorAt.top !== undefined ? `${editorAt.top}px` : null}
      style:bottom={editorAt.bottom !== undefined ? `${editorAt.bottom}px` : null}
      style:max-height={editorAt.maxHeight}
      style:width="{EDITOR_WIDTH}px"
      use:reportInteractiveZone={{ id: "strip-editor" }}
      {@attach editorState().mode === "edit" ? dismissEditor : undefined}
    >
      <editor.default inPopover />
    </div>
  {/await}
{/if}

<style>
  .strip-editor {
    position: fixed;
    z-index: 60;
    display: flex;
    flex-direction: column;
    overflow: clip;
    border-radius: var(--float-radius-popover);
    background-color: var(--sidebar-bg);
    box-shadow: var(--chrome-overlay-shadow);
    pointer-events: auto;
    transform-origin: left bottom;
    animation: editor-in 200ms var(--motion-ease-spring) both;
  }

  .strip-editor.below {
    transform-origin: left top;
  }

  :global(html[data-material='grain']) .strip-editor {
    background-image: var(--grain-texture);
    background-size: 160px;
    background-blend-mode: overlay;
  }

  @keyframes editor-in {
    from {
      opacity: 0;
      transform: scale(0.97);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .strip-editor {
      animation: none;
    }
  }

  .strip-panels {
    position: fixed;
    left: var(--content-inset);
    top: calc(var(--chrome-content-top) + 4px);
    bottom: calc(var(--chrome-content-bottom) + 4px);
    width: var(--sidebar-width);
    /* clip, not hidden: a focus reveal while a panel slides in would scroll it, with no way back. */
    overflow: clip;
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
    bottom: 0;
  }

  /* Inside the frame's border, over the bar the native frame draws, the bottom one mirroring the top; floating in,
     the strip paints its own. */
  :global(html[data-tab-position='top']) .tab-strip-host {
    padding: var(--content-inset) var(--content-inset) 0;
  }

  :global(html[data-tab-position='bottom']) .tab-strip-host {
    padding: 0 var(--content-inset) var(--content-inset);
  }

  :global(html:is([data-tab-position='top'], [data-tab-position='bottom'])) .tab-strip-host:not(.strip-overlay):not(.covers-page) {
    background-color: transparent;
  }

  :global(html[data-material='grain']) .tab-strip-host.covers-page {
    background-image: var(--grain-texture);
    background-size: 160px;
    background-blend-mode: overlay;
  }

  .tab-strip-host.strip-hidden {
    transform: translateY(-100%);
    pointer-events: none;
  }

  :global(html[data-tab-position='bottom']) .tab-strip-host.strip-hidden {
    transform: translateY(100%);
  }

  .tab-strip-host.strip-overlay {
    box-shadow: 0 4px 24px var(--sidebar-shadow);
    z-index: 63;
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
