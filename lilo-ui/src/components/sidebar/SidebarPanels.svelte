<!-- Overlay panels (slide in from right). Split out of the entry chunk; lazy-imported by
     Sidebar.svelte the first time a panel opens. -->
<script lang="ts">
  import { tick } from "svelte";
  import SpaceEditor from "../spaces/SpaceEditor.svelte";
  import DiagnosticsPanel from "../diagnostics/DiagnosticsPanel.svelte";
  import DesignSystemPanel from "../diagnostics/DesignSystemPanel.svelte";
  import DownloadsPanel from "../downloads/DownloadsPanel.svelte";
  import ScreenshotPanel from "../screenshot/ScreenshotPanel.svelte";
  import ProcessManagerPanel from "../diagnostics/ProcessManagerPanel.svelte";
  import SettingsPanel from "../settings/SettingsPanel.svelte";
  import {
    getActivePanel,
    isDesignSystemShellOpen,
    isSettingsShellOpen,
  } from "../../stores/panels.svelte";

  let { active = false }: { active?: boolean } = $props();
  const activePanel = $derived(getActivePanel());
  const openPanel = $derived(
    isSettingsShellOpen() ? "settings" : isDesignSystemShellOpen() ? "designSystem" : activePanel,
  );
  let panelEl: HTMLDivElement | undefined = $state();

  // An opening panel takes the focus to its first control, as a sheet does; Sidebar hands it back.
  $effect(() => {
    if (!active || !openPanel) return;
    void tick().then(() => {
      if (!panelEl || panelEl.contains(document.activeElement)) return;
      const first = Array.from(panelEl.querySelectorAll<HTMLElement>(
        "button:not([disabled]), input:not([disabled]), select, textarea, a[href], [tabindex]:not([tabindex='-1'])",
      )).find((el) => el.checkVisibility({ visibilityProperty: true }) && !el.closest("[inert]"));
      first?.focus({ preventScroll: true });
    });
  });
</script>

<div class="sidebar-panel" class:active bind:this={panelEl}>
  {#if isSettingsShellOpen()}
    <SettingsPanel />
  {/if}
  {#if isDesignSystemShellOpen()}
    <DesignSystemPanel />
  {/if}
  {#if activePanel === "editor"}
    <SpaceEditor />
  {/if}
  {#if activePanel === "diagnostics"}
    <DiagnosticsPanel />
  {/if}
  {#if activePanel === "processes"}
    <ProcessManagerPanel />
  {/if}
  {#if activePanel === "downloads"}
    <DownloadsPanel />
  {/if}
  {#if activePanel === "screenshot"}
    <ScreenshotPanel />
  {/if}
</div>

<style>
  .sidebar-panel {
    position: absolute;
    inset: 0;
    transform: translateX(100%);
    transition: transform 220ms var(--motion-ease-spring);
    pointer-events: none;
  }

  .sidebar-panel.active {
    transform: translateX(0);
    pointer-events: auto;
  }

  /* The chunk mounts on first open with `active` already set: slide in from off-screen anyway. */
  @starting-style {
    .sidebar-panel.active {
      transform: translateX(100%);
    }
  }
</style>
