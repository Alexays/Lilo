<!-- A Little window's whole interface: the command bar as its start view, then the strip over the page it opened. -->
<script lang="ts">
  import { onMount } from "svelte";
  import CommandBar from "../components/commandbar/CommandBar.svelte";
  import Icon from "../components/ui/Icon.svelte";
    import { chromeActions, littleActions } from "../lib/bridge/actions";
  import { t } from "../lib/i18n/state.svelte";
  import { deriveSidebarThemeVariables } from "../lib/sidebarTheme";
  import { closeCommandBar, dockCommandBar, isCommandBarDocked } from "../stores/commandBar.svelte";
  import LittleBar from "./LittleBar.svelte";
  import { getLittleState } from "./little.svelte";

  const little = $derived(getLittleState());
  const colorScheme = window.matchMedia("(prefers-color-scheme: dark)");
  let dark = $state(colorScheme.matches);

  onMount(() => {
    // The command bar sits in the whole window, not beside a sidebar.
    for (const edge of ["left", "right", "top", "bottom"]) {
      document.documentElement.style.setProperty(`--chrome-content-${edge}`, "0px");
    }
    const follow = () => (dark = colorScheme.matches);
    colorScheme.addEventListener("change", follow);
    return () => colorScheme.removeEventListener("change", follow);
  });

  // The Space's palette, as its sidebar wears it.
  $effect(() => {
    const variables = deriveSidebarThemeVariables(little.space.color || undefined, dark);
    for (const [name, value] of Object.entries(variables)) document.documentElement.style.setProperty(name, value);
  });

  // The start view is the bar in place; a page replaces it. The bar over the page (⌘L) closes back to the page.
  $effect(() => {
    if (little.mode === "start") dockCommandBar();
    else if (isCommandBarDocked()) closeCommandBar();
  });

  // Escape closes the window once nothing of the bar is left to leave: the bar takes its own first.
  function handleKeydown(event: KeyboardEvent) {
    if (event.key !== "Escape" || event.defaultPrevented || event.isComposing || little.mode !== "page") return;
    event.preventDefault();
    littleActions.close();
  }

  function startDrag(event: PointerEvent) {
    if (event.button === 0) chromeActions.startWindowDrag();
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="little-app" class:start={little.mode === "start"}>
  {#if little.mode === "start"}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="drag" onpointerdown={startDrag}></div>
    <button type="button" class="close" title={t("common.close")} aria-label={t("common.close")} onclick={littleActions.close}>
      <Icon name="close" size={12} />
    </button>
  {:else}
    <LittleBar {little} />
  {/if}
  <CommandBar
    onEscape={littleActions.close}
    scopes={["all", "history"]}
    copy={{ placeholder: t("little.placeholder"), emptyTitle: t("little.emptyTitle"), emptySubtitle: t("little.emptySubtitle") }}
  />
</div>

<style>
  .little-app :global(.command-bar-backdrop.docked) {
    --bar-top: 44px;
    padding-bottom: 16px;
  }
  .little-app :global(.docked .command-bar) {
    height: 320px;
  }

  .drag {
    position: fixed;
    inset: 0 0 auto 0;
    z-index: 61;
    height: 44px;
  }

  .close {
    position: fixed;
    top: var(--space-8);
    right: var(--space-8);
    z-index: 62;
    display: grid;
    place-items: center;
    width: var(--control-height-md);
    height: var(--control-height-md);
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--sidebar-secondary, var(--text-secondary));
    cursor: pointer;
  }
  .close:hover { background: color-mix(in srgb, var(--sidebar-contrast) 10%, transparent); }
  .close:focus-visible { outline: var(--focus-outline); }
</style>
