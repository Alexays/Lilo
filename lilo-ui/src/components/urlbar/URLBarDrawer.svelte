<!-- The drawer anchored to the address by an arrow. It floats over the tab list or the page and
     never pushes them. It comes in from its arrow and fades out; a different drawer waits for the
     current one to leave before showing. -->
<script lang="ts">
  import { untrack, type ComponentProps } from "svelte";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import {
    getActiveUrlBarDrawer,
    pinSiteDrawer,
    setSiteDrawerOpen,
    type UrlBarDrawer,
  } from "../../stores/urlBarDrawer.svelte";
  import DefaultBrowserDrawer from "./DefaultBrowserDrawer.svelte";
  import PermissionRequestDrawer from "./PermissionRequestDrawer.svelte";
  import SiteDrawer from "./SiteDrawer.svelte";

  let site: ComponentProps<typeof SiteDrawer> = $props();

  // Matches the fade out below.
  const CLOSE_MS = 120;

  const active = $derived(getActiveUrlBarDrawer());
  let shown = $state.raw<UrlBarDrawer | null>(null);
  let open = $state(false);
  let swapTimer: ReturnType<typeof setTimeout> | null = null;

  function drawerKey(drawer: UrlBarDrawer | null): string {
    if (!drawer) return "";
    return "requestId" in drawer ? drawer.requestId : drawer.kind;
  }

  function show(next: UrlBarDrawer | null): void {
    shown = next;
    // A frame closed first, so the drawer mounts small and grows from its arrow.
    if (next) requestAnimationFrame(() => { if (shown === next) open = true; });
  }

  $effect(() => {
    const next = active;
    untrack(() => {
      if (drawerKey(next) === drawerKey(shown)) return;
      if (swapTimer) clearTimeout(swapTimer);
      if (shown && open) {
        open = false;
        swapTimer = setTimeout(() => {
          swapTimer = null;
          show(next);
        }, CLOSE_MS);
      } else {
        show(next);
      }
    });
  });

  $effect(() => () => {
    if (swapTimer) clearTimeout(swapTimer);
  });

  // An extension asks from its own button: the request floats there, over the tabs, instead of pushing them down.
  // With no extensions button on screen (the address hidden), it opens in the drawer like the others.
  const POPOVER_WIDTH = 320;
  const extensionAnchor = $derived(
    shown?.kind === "extensionPermission"
      ? [...document.querySelectorAll<HTMLElement>(".extension-menu-btn")].find((button) => button.checkVisibility()) ?? null
      : null,
  );
  const anchorRect = $derived(extensionAnchor?.getBoundingClientRect());
  const popoverLeft = $derived(anchorRect ? Math.max(8, Math.min(anchorRect.right + 14 - POPOVER_WIDTH, window.innerWidth - POPOVER_WIDTH - 8)) : 0);

</script>

<!-- The Site drawer is the user's own: Escape, a press outside the address bar, or a click in the
     page closes it. Requests stay until answered. -->
{#if shown && !extensionAnchor}
  <div
    class="url-drawer float-surface"
    class:open
    class:wide={shown.kind === "site"}
    role="group"
    use:reportInteractiveZone={{ id: "url-bar-drawer", active: open, outsetY: 12 }}
    onpointerdown={pinSiteDrawer}
    {@attach shown.kind === "site" &&
      dismissable({ onDismiss: () => setSiteDrawerOpen(false), ignore: ".url-display", escape: true })}
  >
    {#if shown.kind === "site"}
      <SiteDrawer {...site} />
    {:else if shown.kind === "defaultBrowser"}
      <DefaultBrowserDrawer />
    {:else}
      <PermissionRequestDrawer request={shown} />
    {/if}
  </div>
{/if}
{#if shown?.kind === "extensionPermission" && anchorRect}
  <div
    class="extension-request float-surface"
    class:open
    style:top="{anchorRect.bottom + 10}px"
    style:left="{popoverLeft}px"
    style:width="{POPOVER_WIDTH}px"
    style:--arrow-x="{anchorRect.left + anchorRect.width / 2 - popoverLeft}px"
    use:portal
    use:reportInteractiveZone={{ id: "extension-request", active: open, outsetY: 6 }}
  >
    <PermissionRequestDrawer request={shown} />
  </div>
{/if}

<style>
  /* Under the address and at least as wide, over the page when the sidebar is narrow. */
  .url-drawer {
    --arrow-inset: 28px;
    position: absolute;
    top: calc(100% + 6px);
    left: 8px;
    right: var(--sidebar-right-pad, 8px);
    min-width: 260px;
    z-index: 30;
    box-sizing: border-box;
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    padding: 12px;
    border-radius: var(--radius-lg);
    opacity: 0;
    transform: scale(0.96);
    transform-origin: var(--arrow-inset) 0;
    transition:
      opacity var(--motion-duration-fast) ease,
      transform var(--motion-duration-fast) ease;
  }

  .url-drawer.wide {
    right: auto;
    width: max(360px, calc(100% - 16px));
    padding: 16px 20px 12px;
  }

  .url-drawer.open {
    opacity: 1;
    transform: none;
    transition:
      opacity var(--motion-duration-overlay) ease-out,
      transform var(--motion-duration-overlay) var(--motion-ease-spring);
  }

  /* The arrow: a corner of the surface pointing at the address. */
  .url-drawer::before {
    content: "";
    position: absolute;
    top: -6px;
    left: calc(var(--arrow-inset) - 6px);
    width: 12px;
    height: 12px;
    border-top-left-radius: var(--radius-2xs);
    background: inherit;
    box-shadow: -1px -1px 0 0 var(--float-border);
    transform: rotate(45deg);
  }

  /* Bridges the gap to the address, so the pointer reaches the drawer without leaving it. Its zone's outsetY covers it. */
  .url-drawer::after {
    content: "";
    position: absolute;
    inset: -12px 0 100% 0;
  }

  :global(.tab-strip.bottom) .url-drawer::after {
    inset: 100% 0 -12px 0;
  }

  /* With the tabs on the right, it grows over the page to the left. */
  :global(html[data-tab-position='right']) .url-drawer {
    left: auto;
    right: var(--sidebar-right-pad, 8px);
    transform-origin: calc(100% - var(--arrow-inset)) 0;
  }

  :global(html[data-tab-position='right']) .url-drawer::before {
    left: auto;
    right: calc(var(--arrow-inset) - 6px);
  }

  /* From the address in a bottom bar, it opens upward. */
  :global(.tab-strip.bottom) .url-drawer {
    top: auto;
    bottom: calc(100% + 6px);
    transform-origin: var(--arrow-inset) 100%;
  }

  :global(.tab-strip.bottom) .url-drawer::before {
    top: auto;
    bottom: -6px;
    border-top-left-radius: 0;
    border-bottom-right-radius: var(--radius-2xs);
    box-shadow: 1px 1px 0 0 var(--float-border);
  }

  .extension-request {
    position: fixed;
    z-index: var(--z-popover);
    padding: 14px 12px 10px;
    border-radius: var(--radius-lg);
    background: var(--float-surface);
    box-shadow: var(--float-shadow);
    pointer-events: auto;
    opacity: 0;
    transform: translateY(-4px) scale(0.98);
    transform-origin: var(--arrow-x) 0;
    transition:
      opacity var(--motion-duration-fast) ease,
      transform var(--motion-duration-overlay) var(--motion-ease-spring);
  }

  .extension-request.open {
    opacity: 1;
    transform: none;
  }

  /* Points at the button that asks. */
  .extension-request::before {
    content: "";
    position: absolute;
    top: -6px;
    left: calc(var(--arrow-x) - 6px);
    width: 12px;
    height: 12px;
    border-radius: var(--radius-2xs) 0 0;
    background: inherit;
    box-shadow: -1px -1px 0 var(--float-border);
    transform: rotate(45deg);
  }

  @media (prefers-reduced-motion: reduce) {
    .url-drawer,
    .extension-request,
    .url-drawer.open {
      transform: none;
      transition: opacity var(--motion-duration-fast) ease;
    }
  }
</style>
