<script lang="ts">
  import { setThemeContext } from "./stores/theme.svelte";
  import { onMount, untrack } from "svelte";
  import Sidebar from "./components/sidebar/Sidebar.svelte";
  import SplitDropZone from "./components/page/SplitDropZone.svelte";
  import { chromeActions } from "./lib/bridge/actions";
  import {
    deriveSidebarThemeVariables,
    interpolateHexColors,
  } from "./lib/sidebarTheme";
  import { isBridgeReady, on } from "./lib/bridge";
  import { onChromeInitialStateReady } from "./stores/init";
  import { getOnboarding } from "./stores/onboarding.svelte";
  import { getActiveUrlBarDrawer } from "./stores/urlBarDrawer.svelte";
  import { editorState } from "./stores/panels.svelte";
  import { getPagedSpaces, getSpacePagerVirtualIndex } from "./stores/pager.svelte";
  import { getFocusedSpaceId, getSpaceById } from "./stores/spaces.svelte";
  import { getActiveTab } from "./stores/tabs.svelte";
  import { getDayPart, getWallpaperColor, watchDayPart, watchWallpaperColor } from "./stores/spaceColor.svelte";
  import { effectiveSpaceColor } from "./lib/spaceColor";
  import type { SpaceColorMode } from "./lib/bridge/protocol";
  import {
    hideSidebarOverlay,
    isFullscreen,
    isSidebarOverlay,
    isSidebarShown,
    isSidebarVisible,
    showSidebarOverlay,
  } from "./stores/ui.svelte";
  import { reportInteractiveZone } from "./lib/actions/interactiveZone";
  import { getTabPosition, hasPageToolbar, isPageToolbarShown, isVerticalLayout } from "./stores/tabLayout.svelte";
  import { isLiftingTabs } from "./stores/tabEdgeDrag.svelte";
  import { createFrameScheduler } from "./lib/motion/frameScheduler";
  import { clearAllHover } from "./lib/hoverClear";

  const SIDEBAR_OVERLAY_HIDE_DELAY_MS = 70;
  // One query object for the lifetime of the app: applySidebarTheme and the swipe background read it.
  const colorSchemeQuery = window.matchMedia("(prefers-color-scheme: dark)");

  // What the native host has actually received. Starts empty even though the bootstrap seeds
  // --sidebar-bg: that seed is the cached color, and the frame bands are painted from the space
  // accent re-derived natively, so the two can differ until the UI's own value gets through.
  let lastReportedSidebarBackground = "";
  let showDeferredChrome = $state(false);
  // The two Spaces a swipe is between, and how far it is: null outside a swipe.
  const swipe = $derived.by(() => {
    // The pager's index counts only the spaces it pages through (the hidden Agents space is out).
    const spaces = getPagedSpaces();
    if (spaces.length === 0) return null;
    const index = Math.max(0, Math.min(spaces.length - 1, getSpacePagerVirtualIndex()));
    const leading = Math.floor(index);
    const progress = index - leading;
    if (progress === 0) return null;
    const leadingColor = spaceChromeColor(spaces[leading]);
    const trailing = spaces[leading + 1];
    return { leadingColor, trailingColor: trailing ? spaceChromeColor(trailing) : leadingColor, progress };
  });
  // Each source is read only by the mode that uses it, so a fixed Space never tracks the active tab.
  function chromeColor(mode: SpaceColorMode | undefined, color: string, spaceId: string): string {
    return effectiveSpaceColor(mode, color, {
      dayPart: mode === "time" ? getDayPart() : "day",
      pageColor: mode === "page" ? getActiveTab(spaceId)?.faviconDominantColor : undefined,
      wallpaperColor: mode === "wallpaper" ? getWallpaperColor() : undefined,
    });
  }
  function spaceChromeColor(space: { id: string; color: string; colorMode?: SpaceColorMode } | undefined): string {
    return space ? chromeColor(space.colorMode, space.color, space.id) : "";
  }
  // The mode on screen: the open editor's choice, else the focused Space's. Its source is watched only meanwhile.
  const shownColorMode = $derived(
    editorState().open ? editorState().colorMode : getSpaceById(getFocusedSpaceId())?.colorMode,
  );
  $effect(() => {
    if (shownColorMode === "time") return watchDayPart();
  });
  $effect(() => {
    if (shownColorMode === "wallpaper") return watchWallpaperColor();
  });
  // The whole theme switches once, at the swipe's midpoint: each change rewrites ~20 root custom properties
  // and restyles the whole chrome document. Only the sidebar background follows the finger (swipeBackground).
  const themeSidebarColor = $derived.by(() => {
    // The open Space editor previews its color on the whole chrome, the window frame included.
    const currentEditor = editorState();
    if (currentEditor.open && currentEditor.color) {
      return chromeColor(currentEditor.colorMode, currentEditor.color, currentEditor.spaceId || getFocusedSpaceId());
    }
    if (swipe) return swipe.progress < 0.5 ? swipe.leadingColor : swipe.trailingColor;
    return spaceChromeColor(getSpaceById(getFocusedSpaceId()));
  });
  // Set on the sidebar element alone, so a swipe frame restyles that one element instead of the document.
  const swipeBackground = $derived.by(() => {
    if (!swipe || swipe.leadingColor === swipe.trailingColor || editorState().open) return null;
    const dark = colorSchemeQuery.matches;
    return interpolateHexColors(
      sidebarBackground(swipe.leadingColor, dark),
      sidebarBackground(swipe.trailingColor, dark),
      swipe.progress,
    );
  });
  // A swipe asks for the same two Spaces on every frame: their derived backgrounds are kept.
  let sidebarBackgrounds: Record<string, string> = {};
  function sidebarBackground(color: string, dark: boolean): string {
    const key = `${dark}${color}`;
    let background = sidebarBackgrounds[key];
    if (background === undefined) {
      if (Object.keys(sidebarBackgrounds).length > 16) sidebarBackgrounds = {};
      background = deriveSidebarThemeVariables(color, dark)["--sidebar-bg"];
      sidebarBackgrounds[key] = background;
    }
    return background;
  }
  let pendingBgReportTimeout: ReturnType<typeof setTimeout> | null = null;
  let lastThemeVars: Record<string, string> = {};
  let sidebarOverlayHideTimeout: ReturnType<typeof setTimeout> | null = null;
  const sidebarResizeFrame = createFrameScheduler();
  let pendingSidebarWidth = 260;
  let isSidebarResizing = $state(false);

  function applySidebarTheme() {
    const root = document.documentElement;
    const variables = deriveSidebarThemeVariables(
      themeSidebarColor,
      colorSchemeQuery.matches,
    );

    for (const [name, value] of Object.entries(variables)) {
      if (lastThemeVars[name] !== value) {
        root.style.setProperty(name, value);
        lastThemeVars[name] = value;
      }
    }
    setThemeContext(variables["--sidebar-bg"], colorSchemeQuery.matches);
  }

  function reportSidebarBg() {
    // Derive the bg from the already-computed theme vars: no getComputedStyle.
    // Fall back to the inline-style value (set by applySidebarTheme via setProperty) during
    // the bootstrap window before the first theme apply.
    const bg =
      lastThemeVars["--sidebar-bg"] ||
      document.documentElement.style.getPropertyValue("--sidebar-bg").trim();
    if (!bg || bg === lastReportedSidebarBackground) {
      return;
    }
    // Dropping the report here rather than latching it: the next theme change retries, and the
    // initial state always brings one because it carries the real active space.
    if (!isBridgeReady()) {
      return;
    }

    lastReportedSidebarBackground = bg;
    chromeActions.updateWindowBackground(bg);
  }

  function scheduleSidebarBackgroundReport() {
    if (pendingBgReportTimeout !== null) {
      return; // trailing-edge: let the existing timeout fire
    }

    pendingBgReportTimeout = setTimeout(() => {
      pendingBgReportTimeout = null;
      reportSidebarBg();
    }, 100);
  }

  function cancelSidebarOverlayHide() {
    if (sidebarOverlayHideTimeout === null) {
      return;
    }

    clearTimeout(sidebarOverlayHideTimeout);
    sidebarOverlayHideTimeout = null;
  }

  function scheduleSidebarOverlayHide() {
    if (!isSidebarOverlay()) {
      return;
    }

    cancelSidebarOverlayHide();
    sidebarOverlayHideTimeout = setTimeout(() => {
      sidebarOverlayHideTimeout = null;
      hideSidebarOverlay();
    }, SIDEBAR_OVERLAY_HIDE_DELAY_MS);
  }

  function openSidebarOverlay() {
    cancelSidebarOverlayHide();
    showSidebarOverlay();
  }

  // A request lives under the address bar: a hidden sidebar slides out so it can be seen, and stays until the pointer leaves it.
  $effect(() => {
    const drawer = getActiveUrlBarDrawer();
    if (drawer && "requestId" in drawer) untrack(openSidebarOverlay);
  });

  function blurChromeFocus() {
    const active = document.activeElement;
    if (active instanceof HTMLElement && active.closest("#chrome-root")) {
      active.blur();
    }
  }

  function startResize(e: MouseEvent) {
    e.preventDefault();
    cancelSidebarOverlayHide();
    isSidebarResizing = true;

    const root = document.documentElement;
    const startX = e.clientX;
    const startWidth =
      parseInt(getComputedStyle(root).getPropertyValue("--sidebar-width")) ||
      260;

    pendingSidebarWidth = startWidth;

    function applyPendingSidebarWidth() {
      root.style.setProperty("--sidebar-width", `${pendingSidebarWidth}px`);
      chromeActions.sidebarResized(pendingSidebarWidth);
    }

    function scheduleSidebarWidth(width: number) {
      pendingSidebarWidth = width;
      sidebarResizeFrame.schedule(applyPendingSidebarWidth);
    }

    function onMove(ev: MouseEvent) {
      // On the right the handle sits on the sidebar's left edge: dragging left widens it.
      const delta = getTabPosition() === "right" ? startX - ev.clientX : ev.clientX - startX;
      const newWidth = Math.max(200, Math.min(480, startWidth + delta));
      scheduleSidebarWidth(newWidth);
    }

    function onUp() {
      // Flush the coalesced width now so the final size is committed on release.
      if (sidebarResizeFrame.cancel()) {
        applyPendingSidebarWidth();
      }

      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      document.body.style.cursor = "";
      isSidebarResizing = false;
    }

    document.body.style.cursor = "col-resize";
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  }

  $effect(() => {
    applySidebarTheme();
    scheduleSidebarBackgroundReport();
  });

  onMount(() => {
    const handleColorSchemeChange = () => {
      applySidebarTheme();
      scheduleSidebarBackgroundReport();
    };

    colorSchemeQuery.addEventListener("change", handleColorSchemeChange);
    // A press only: the pointer merely crossing into the page must not blur a chrome field, and a blur
    // ends a color input's picker, eyedropper included.
    const disposeContentInteraction = on("contentInteraction", ({ isMouseDown }) => {
      if (isMouseDown) blurChromeFocus();
    });
    const disposeWindowFocus = on("windowFocusChanged", ({ focused }) => {
      document.documentElement.classList.toggle("window-unfocused", !focused);
      if (!focused) clearAllHover();
    });

    const disposeInitialStateReady = onChromeInitialStateReady(() => {
      chromeActions.startupMark("chromeVisualReadyScheduled");
      // Dated at the frame that paints the revealed chrome, the moment the interface is actually visible.
      requestAnimationFrame(() => {
        // Revealed in the frame itself, after the onboarding state sent with the initial state: under
        // the intro, the onboarding shell reveals the chrome once the intro is mounted.
        const onboarding = getOnboarding();
        if (!onboarding.visible || onboarding.step !== 0) document.documentElement.removeAttribute("data-booting");
        chromeActions.markVisualReady(performance.timeOrigin + performance.now());
      });
      // Reveal deferred chrome (overlays/modals) in the same turn the skeleton becomes visible:
      // the Svelte tree is already mounted by onMount, so waiting a frame gains no DOM stability.
      showDeferredChrome = true;
    });

    return () => {
      if (pendingBgReportTimeout !== null) {
        clearTimeout(pendingBgReportTimeout);
      }
      sidebarResizeFrame.cancel();
      cancelSidebarOverlayHide();
      disposeInitialStateReady();
      disposeContentInteraction();
      disposeWindowFocus();
      colorSchemeQuery.removeEventListener("change", handleColorSchemeChange);
    };
  });
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  id="chrome-root"
  class:sidebar-resizing={isSidebarResizing}
  class:fullscreen={isFullscreen()}
  oncontextmenu={(e) => e.preventDefault()}
>
  <!-- The frame around the content area (sidebar band, inset ring, rounded corners)
       is painted natively by WindowFrameView, so nothing full-viewport here. -->

  <!-- Double-click inset padding to maximize -->
  <!-- A docked toolbar or strip over the page handles its own window drag. -->
  <div
    class="content-inset-zone"
    class:sidebar-hidden={!isSidebarVisible()}
    class:zone-inactive={isSidebarVisible() && (hasPageToolbar() || !isVerticalLayout())}
    use:reportInteractiveZone={{ id: "content-inset-zone", active: !isSidebarVisible() || (!hasPageToolbar() && isVerticalLayout()) }}
  ></div>

  {#if isPageToolbarShown()}
    <!-- Loaded on demand: the default left layout's first paint carries none of it. -->
    {#await import("./components/page/PageToolbar.svelte") then toolbar}
      <toolbar.default row={getTabPosition() === "top" && isSidebarVisible()} />
    {/await}
  {/if}

  <SplitDropZone />

  {#if !isVerticalLayout()}
    <!-- Loaded on demand: the default left layout's first paint carries none of it. -->
    {#await import("./components/strip/StripHost.svelte") then host}
      <host.default onenter={cancelSidebarOverlayHide} onleave={scheduleSidebarOverlayHide} />
    {/await}
  {:else}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="sidebar tabs-surface"
    class:sidebar-hidden={!isSidebarShown()}
    class:sidebar-overlay={isSidebarOverlay()}
    class:swiping={swipeBackground !== null}
    style:background-color={swipeBackground}
    use:reportInteractiveZone={{ id: "sidebar", active: isSidebarShown() }}
    onmouseenter={cancelSidebarOverlayHide}
    onmouseleave={scheduleSidebarOverlayHide}
  >
    <Sidebar />
    {#if isSidebarVisible()}
      <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
      <div
        class="sidebar-resize-handle"
        role="separator"
        aria-orientation="vertical"
        onmousedown={startResize}
      ></div>
    {/if}
  </div>
  {/if}

  <!-- Always mounted; active prop + CSS visibility controlled by sidebar mode -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="sidebar-overlay-tolerance"
    class:zone-inactive={!isSidebarOverlay()}
    use:reportInteractiveZone={{
      id: "sidebar-overlay-tolerance",
      active: isSidebarOverlay(),
    }}
    onmouseenter={cancelSidebarOverlayHide}
    onmouseleave={scheduleSidebarOverlayHide}
  ></div>

  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="sidebar-hover-trigger"
    class:zone-inactive={isSidebarShown()}
    use:reportInteractiveZone={{
      id: "sidebar-hover-trigger",
      active: !isSidebarShown(),
    }}
    onmouseenter={openSidebarOverlay}
    onmouseleave={scheduleSidebarOverlayHide}
  ></div>

  {#if isLiftingTabs()}
    {#await import("./components/page/TabEdgeDrag.svelte") then edgeDrag}
      <edgeDrag.default />
    {/await}
  {/if}

  {#if showDeferredChrome}
    {#await import("./components/DeferredChrome.svelte") then deferred}
      <deferred.default />
    {/await}
  {/if}
</div>

<style>
  #chrome-root {
    position: fixed;
    inset: 0;
    pointer-events: none;
    opacity: 1;
    transition: opacity var(--motion-duration-normal) var(--motion-ease-organic);
  }

  @media (prefers-reduced-motion: reduce) {
    #chrome-root {
      transition: none;
    }
  }

  #chrome-root.sidebar-resizing .sidebar {
    transition: none;
  }

  /* Invisible hit zone: snaps to its final position on sidebar toggle (no transition)
     so the toggle stays compositor-only; the zone re-reports via ResizeObserver. */
  .content-inset-zone {
    position: fixed;
    top: 0;
    left: var(--chrome-content-left-visible);
    right: 0;
    height: var(--chrome-content-top);
    pointer-events: auto;
    z-index: 5;
  }

  .content-inset-zone.sidebar-hidden {
    left: 0;
  }

  .sidebar-hover-trigger {
    position: fixed;
    top: 0;
    left: 0;
    width: 10px;
    height: 100vh;
    pointer-events: auto;
    z-index: 100;
  }

  :global(html[data-tab-position='right']) .sidebar-hover-trigger {
    left: auto;
    right: 0;
  }

  .sidebar-overlay-tolerance {
    position: fixed;
    top: 0;
    left: var(--sidebar-column);
    width: calc(var(--chrome-overlay-edge-gap) + 4px);
    height: 100vh;
    pointer-events: auto;
    z-index: 49;
  }

  /* The strip layouts reveal from a full-width edge. */
  :global(html[data-tab-position='top']) .sidebar-hover-trigger,
  :global(html[data-tab-position='bottom']) .sidebar-hover-trigger {
    width: 100vw;
    height: 6px;
  }

  :global(html[data-tab-position='bottom']) .sidebar-hover-trigger {
    top: auto;
    bottom: 0;
  }

  :global(html[data-tab-position='top']) .sidebar-overlay-tolerance,
  :global(html[data-tab-position='bottom']) .sidebar-overlay-tolerance {
    left: 0;
    width: 100vw;
    height: calc(var(--chrome-overlay-edge-gap) + 4px);
  }

  :global(html[data-tab-position='top']) .sidebar-overlay-tolerance {
    top: var(--top-strip-height);
  }

  :global(html[data-tab-position='bottom']) .sidebar-overlay-tolerance {
    top: auto;
    bottom: calc(var(--bottom-dock-height) + 2 * var(--bottom-dock-margin));
  }

  /* Lifted by a held press: the tabs float until dropped on an edge. */
  :global(html[data-tabs-lifting]) .sidebar {
    transform: translate(var(--lift-x, 0px), var(--lift-y, 0px)) scale(0.96);
    transition: box-shadow var(--motion-duration-slow) ease;
    border-radius: var(--radius-lg);
    overflow: hidden;
    box-shadow: var(--chrome-overlay-shadow);
    z-index: 72;
  }

  :global(html[data-tab-position='right']) .sidebar-overlay-tolerance {
    left: auto;
    right: var(--sidebar-column);
  }

  .zone-inactive {
    display: none;
  }

  .sidebar {
    position: fixed;
    top: 0;
    left: 0;
    width: var(--sidebar-column);
    height: 100vh;
    background-color: var(--sidebar-bg);
    pointer-events: auto;
    display: flex;
    flex-direction: column;
    contain: layout style;
    transition:
      transform var(--motion-duration-slow) var(--motion-ease-standard),
      box-shadow var(--motion-duration-slow) ease,
      background-color var(--motion-duration-slow) var(--motion-ease-spring);
    z-index: 10;
  }

  /* The background follows the finger frame by frame: easing it would make it lag behind. */
  .sidebar.swiping {
    transition:
      transform var(--motion-duration-slow) var(--motion-ease-standard),
      box-shadow var(--motion-duration-slow) ease;
  }

  /* Painted with --sidebar-bg, which switches only at the midpoint: see-through while the background slides. */
  .sidebar.swiping :global(.pinned-tab-divider-shell),
  .sidebar.swiping :global(.clear-unpinned) {
    background: transparent;
  }

  .sidebar.sidebar-hidden {
    transform: translateX(-100%);
    pointer-events: none;
  }

  :global(html[data-tab-position='right']) .sidebar {
    left: auto;
    right: 0;
  }

  :global(html[data-tab-position='right']) .sidebar.sidebar-hidden {
    transform: translateX(100%);
  }

  /* Off-screen, not removed: looping spinners and pips would keep the compositor busy.
     Same list as html.window-unfocused in global.css. */
  .sidebar.sidebar-hidden :global(.tab-loader span),
  .sidebar.sidebar-hidden :global(.url-progress-fill),
  .sidebar.sidebar-hidden :global(.url-progress-fill::after),
  .sidebar.sidebar-hidden :global(.skeleton-shimmer),
  .sidebar.sidebar-hidden :global(.extension-spinner svg),
  .sidebar.sidebar-hidden :global(.sidebar-dnd-placeholder),
  .sidebar.sidebar-hidden :global(.space-dnd-placeholder),
  .sidebar.sidebar-hidden :global(.bookmark-placeholder),
  .sidebar.sidebar-hidden :global(.pinned-list),
  .sidebar.sidebar-hidden :global(.bookmarked-list) {
    animation-play-state: paused !important;
  }

  .sidebar.sidebar-overlay {
    box-shadow: 4px 0 24px var(--sidebar-shadow);
    z-index: 50;
  }

  :global(html[data-tab-position='right']) .sidebar.sidebar-overlay {
    box-shadow: -4px 0 24px var(--sidebar-shadow);
  }

  .sidebar-resize-handle {
    position: absolute;
    top: 0;
    right: 0;
    width: 7px;
    height: 100%;
    cursor: col-resize;
    z-index: 10;
  }

  :global(html[data-tab-position='right']) .sidebar-resize-handle {
    right: auto;
    left: 0;
  }

  .sidebar-resize-handle:hover,
  .sidebar-resize-handle:active {
    background: var(--accent-tint-12);
  }
</style>
