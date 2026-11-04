<!-- Overlay panels (slide in from right). Split out of the entry chunk; lazy-imported by
     Sidebar.svelte the first time a panel opens. -->
<script lang="ts">
  import { tick } from "svelte";
  import SpaceEditor from "../spaces/SpaceEditor.svelte";
  import DiagnosticsNav from "../diagnostics/DiagnosticsNav.svelte";
  import DesignSystemPanel from "../diagnostics/DesignSystemPanel.svelte";
  import DownloadsNav from "../downloads/DownloadsNav.svelte";
  import ScreenshotPanel from "../screenshot/ScreenshotPanel.svelte";
  import ProcessManagerNav from "../diagnostics/ProcessManagerNav.svelte";
  import SettingsPanel from "../settings/SettingsPanel.svelte";
  import HistoryNav from "../history/HistoryNav.svelte";
  import { getActivePanel, getPageShell, isDesignSystemShellOpen } from "../../stores/panels.svelte";
  import { isVerticalLayout } from "../../stores/tabLayout.svelte";

  let { active = false }: { active?: boolean } = $props();
  const activePanel = $derived(getActivePanel());
  const pageShell = $derived(isVerticalLayout() ? getPageShell() : null);
  const openPanel = $derived(pageShell ?? (isDesignSystemShellOpen() ? "designSystem" : activePanel));
  let panelEl: HTMLDivElement | undefined = $state();

  // An opening panel takes the focus itself, not its first control: a script focus after Cmd+,
  // would ring that control. Sidebar hands the focus back.
  $effect(() => {
    if (!active || !openPanel) return;
    void tick().then(() => {
      if (!panelEl || panelEl.contains(document.activeElement)) return;
      const shell = Array.from(panelEl.querySelectorAll<HTMLElement>(".panel-shell"))
        .find((el) => el.checkVisibility({ visibilityProperty: true }));
      if (!shell) return;
      shell.tabIndex = -1;
      shell.focus({ preventScroll: true });
    });
  });
</script>

<div class="sidebar-panel" class:active bind:this={panelEl}>
  <!-- A system screen's navigation; with a tab strip it sits inside the screen instead. -->
  {#if pageShell === "settings"}
    <SettingsPanel />
  {:else if pageShell === "history"}
    <HistoryNav />
  {:else if pageShell === "downloads"}
    <DownloadsNav />
  {:else if pageShell === "processes"}
    <ProcessManagerNav />
  {:else if pageShell === "diagnostics"}
    <DiagnosticsNav />
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

  .sidebar-panel :global(.panel-shell:focus) {
    outline: none;
  }

  /* The chunk mounts on first open with `active` already set: slide in from off-screen anyway. */
  @starting-style {
    .sidebar-panel.active {
      transform: translateX(100%);
    }
  }
</style>
