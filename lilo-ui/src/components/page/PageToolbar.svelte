<script lang="ts">
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";
  import NavControls from "../sidebar/NavControls.svelte";
  import URLDisplay from "../urlbar/URLDisplay.svelte";
  import { chromeActions } from "../../lib/bridge/actions";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { getTabPosition, isAddressInPageToolbar, isAddressInRightTabs } from "../../stores/tabLayout.svelte";
  import { areTrafficLightsVisible, isSidebarVisible } from "../../stores/ui.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { pageBarStyle } from "../../lib/pageBarTheme";
  import { shellBarColor } from "../../stores/theme.svelte";
  import { createFrameScheduler } from "../../lib/motion/frameScheduler";

  let { row = false, accent }: { row?: boolean; accent: string } = $props();

  // Read apart from the tab, whose every progress tick would otherwise derive the style again.
  const pageColor = $derived(shellBarColor() ?? getActiveTab()?.pageColor);
  const style = $derived(pageBarStyle(pageColor, accent));
  // With the tabs at the bottom and no address here, the bar names the page as a title bar does.
  const title = $derived(getTabPosition() === "bottom" && !isAddressInPageToolbar() ? getActiveTab()?.title ?? "" : null);

  const navigationInStrip = $derived(getTabPosition() === "bottom" && !isAddressInPageToolbar());

  // The traffic lights sit top-left of the window: room for them when the toolbar starts there.
  const besideTrafficLights = $derived(!row && (getTabPosition() !== "left" || !isSidebarVisible()) && areTrafficLightsVisible());

  // The address text centers on its field: the room its trailing buttons take on the right (capture,
  // pinned extensions) is mirrored on the left, measured since that cluster grows and shrinks.
  let addressEl: HTMLDivElement | undefined = $state();
  $effect(() => {
    const el = addressEl;
    if (!el) return;
    // Layout offsets of the shell, not the text's painted box: an address change flies the text in
    // and out under transforms, which would skew the balance mid-motion.
    const measure = () => {
      const trigger = el.querySelector<HTMLElement>(".url-trigger");
      const shell = el.querySelector<HTMLElement>(".url-text-shell");
      if (!trigger || !shell) return;
      // The room right of the shell minus the room left of it, less its sliding end margin: the
      // styles below add that margin back with the same slide.
      const endMargin = parseFloat(getComputedStyle(shell).marginRight) || 0;
      const next = Math.max(0, Math.round(trigger.clientWidth - shell.offsetWidth - 2 * shell.offsetLeft - endMargin));
      if (next !== (parseFloat(el.style.getPropertyValue("--address-balance")) || 0)) {
        el.style.setProperty("--address-balance", `${next}px`);
      }
    };
    // The field renders after this container, and its address and buttons change: watch both.
    const resize = new ResizeObserver(measure);
    resize.observe(el);
    // Mutations land in several batches a frame (counters, transitions): one layout read per frame.
    const frame = createFrameScheduler();
    const mutation = new MutationObserver(() => frame.schedule(measure));
    mutation.observe(el, { childList: true, subtree: true, characterData: true });
    return () => {
      resize.disconnect();
      mutation.disconnect();
      frame.cancel();
    };
  });

  function startWindowDrag(event: PointerEvent) {
    if (event.button !== 0) return;
    if ((event.target as HTMLElement | null)?.closest("button, a, input, select, textarea, [role='button'], .url-display")) return;
    pressTabsHeader(event);
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="page-toolbar tabs-surface"
  class:row
  class:collapsed={!isSidebarVisible()}
  {style}
  use:reportInteractiveZone={{ id: "page-toolbar" }}
  onpointerdown={startWindowDrag}
  ondblclick={(event) => {
    if (!(event.target as HTMLElement).closest("button, .url-display")) chromeActions.maximizeWindow();
  }}
>
  {#if !row && areTrafficLightsVisible()}
    <div class="lights-spacer" class:shut={!besideTrafficLights}></div>
  {/if}
  <!-- Under a top strip, the strip already holds the navigation: this row is the address alone. Without
       the tabs, or beside the left sidebar, it holds their toggle too. Over a bottom strip, the history
       stays with the address: without one here, it goes down to the strip. -->
  {#if !row && !(navigationInStrip && isSidebarVisible())}
    <NavControls show={!isSidebarVisible() || getTabPosition() === "left" ? "all" : isAddressInRightTabs() ? "toggle" : "history"} />
  {/if}
  {#if isAddressInPageToolbar()}
    <div class="address" bind:this={addressEl}><URLDisplay /></div>
  {:else if title !== null}
    <span class="title">{title}</span>
  {/if}
</div>

<style>
  .page-toolbar {
    position: fixed;
    top: 0;
    left: var(--chrome-content-left);
    right: var(--chrome-content-right);
    height: var(--page-toolbar-height);
    display: flex;
    align-items: center;
    gap: 8px;
    padding: var(--content-inset) 4px 0;
    box-sizing: border-box;
    pointer-events: auto;
    /* Its edges slide with the native page (WindowFrameView.toggleDuration). */
    transition:
      left var(--motion-duration-slow) var(--motion-ease-standard),
      right var(--motion-duration-slow) var(--motion-ease-standard);
    /* Over the command bar's page veil: the address drawers hang from here into the page, as they hang beside it from the sidebar. */
    z-index: 61;
  }

  /* Hiding the sidebar, the native page edge leads by two frames, the chrome hearing of the toggle later:
     the bar and the lights' reserve start that far in. */
  .page-toolbar.collapsed,
  .page-toolbar.collapsed .lights-spacer {
    transition-delay: -32ms;
  }

  :global(#chrome-root.sidebar-resizing) .page-toolbar {
    transition: none;
  }

  .page-toolbar.row {
    top: var(--top-strip-height);
    padding-top: 0;
  }

  /* The sidebar header spreads its controls; the toolbar keeps them together on the left, in the capsule the
     tab strip gives its tools. */
  .page-toolbar > :global(.nav-controls) {
    flex: none;
    gap: 2px;
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--text-primary) 6%, transparent);
  }

  /* Matches the sidebar header's reserve for the traffic lights. */
  .lights-spacer {
    width: 72px;
    flex-shrink: 0;
    /* Opens and shuts as the bar slides under the lights or away from them. */
    transition:
      width var(--motion-duration-slow) var(--motion-ease-standard),
      margin-right var(--motion-duration-slow) var(--motion-ease-standard);
  }

  /* The flex gap would still reserve room beside an empty spacer. */
  .lights-spacer.shut {
    width: 0;
    margin-right: -8px;
  }

  /* Centered on the page, whatever sits beside it; an open drawer grows it down into the page, never off the window. */
  .address {
    position: absolute;
    top: calc(var(--content-inset) + (var(--page-toolbar-height) - var(--content-inset) - 32px) / 2);
    left: 50%;
    transform: translateX(-50%);
    width: min(480px, 100% - 2 * 180px);
  }

  .row .address {
    top: calc((var(--page-toolbar-height) - 32px) / 2);
  }

  /* Clicks go through to the bar, which drags and zooms the window. */
  .title {
    position: absolute;
    top: var(--content-inset);
    left: 50%;
    transform: translateX(-50%);
    max-width: calc(100% - 2 * 180px);
    line-height: calc(var(--page-toolbar-height) - var(--content-inset));
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    color: var(--text-secondary);
    pointer-events: none;
  }

  .address > :global(.url-display) {
    padding: 0;
  }

  /* Centered in its field, as Safari centers the address in its toolbar. */
  .address :global(.url-text-line) {
    justify-content: center;
  }

  /* The cluster's share mirrors URLHost's end margin and its slide. */
  .address :global(.url-text-shell) {
    padding-left: calc(var(--address-balance, 0px) + var(--url-cluster-width, 0px) + 4px);
    transition:
      margin-right var(--motion-duration-slow) var(--motion-ease-spring),
      padding-left var(--motion-duration-slow) var(--motion-ease-spring),
      --url-reveal-mask var(--motion-duration-normal) ease;
  }

  .address :global(.url-text-content) {
    width: auto;
    flex: 0 1 auto;
  }

  .address :global(.url-path) {
    flex: 0 1 auto;
  }
</style>
