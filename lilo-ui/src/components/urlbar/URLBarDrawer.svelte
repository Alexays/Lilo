<!-- The drawer that grows out of the address bar. It lives inside the bar's own surface, so the
     two read as one shape. Opening rides Lilo's spring and staggers the rows in; closing is
     quick and plain. A different drawer waits for the current one to close before opening. -->
<script lang="ts">
  import { untrack, type ComponentProps } from "svelte";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import {
    getActiveUrlBarDrawer,
    setSiteDrawerOpen,
    type UrlBarDrawer,
  } from "../../stores/urlBarDrawer.svelte";
  import DefaultBrowserDrawer from "./DefaultBrowserDrawer.svelte";
  import PermissionRequestDrawer from "./PermissionRequestDrawer.svelte";
  import SiteDrawer from "./SiteDrawer.svelte";

  let site: ComponentProps<typeof SiteDrawer> = $props();

  // Matches the collapse transition below.
  const CLOSE_MS = 200;

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
    // A frame at 0fr first, so the content mounts collapsed and the growth animates.
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

</script>

<!-- The Site drawer is the user's own: Escape, a press outside the address bar, or a click in the
     page closes it. Requests stay until answered. -->
<div
  class="url-drawer"
  class:open
  use:reportInteractiveZone={{ id: "url-bar-drawer", active: open }}
  {@attach shown?.kind === "site" &&
    dismissable({ onDismiss: () => setSiteDrawerOpen(false), ignore: ".url-display", escape: true })}
>
  <div class="url-drawer-clip">
    <div class="url-drawer-content">
      {#if shown?.kind === "site"}
        <SiteDrawer {...site} />
      {:else if shown?.kind === "defaultBrowser"}
        <DefaultBrowserDrawer />
      {:else if shown}
        <PermissionRequestDrawer request={shown} />
      {/if}
    </div>
  </div>
</div>

<style>
  .url-drawer {
    display: grid;
    /* minmax: without it the column takes the content's min-content width and overflows. */
    grid-template-columns: minmax(0, 1fr);
    grid-template-rows: 0fr;
    transition: grid-template-rows 200ms var(--motion-ease-standard);
  }

  .url-drawer.open {
    grid-template-rows: 1fr;
    transition: grid-template-rows 380ms var(--motion-ease-bounce);
  }

  .url-drawer-clip {
    min-height: 0;
    overflow: hidden;
  }

  .url-drawer-content {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 1px;
    padding: 0 4px 6px;
  }

  /* Rows leave first on close, then arrive one after another once the surface has grown. */
  .url-drawer-content > :global(*) {
    opacity: 0;
    transform: translateY(-4px);
    transition:
      opacity var(--motion-duration-fast) ease,
      transform 120ms ease;
  }

  .url-drawer.open .url-drawer-content > :global(*) {
    opacity: 1;
    transform: none;
    transition:
      opacity var(--motion-duration-normal) ease-out,
      transform 320ms var(--motion-ease-spring);
    transition-delay: 60ms;
  }

  .url-drawer.open .url-drawer-content > :global(:nth-child(2)) { transition-delay: 88ms; }
  .url-drawer.open .url-drawer-content > :global(:nth-child(3)) { transition-delay: 116ms; }
  .url-drawer.open .url-drawer-content > :global(:nth-child(4)) { transition-delay: 144ms; }
  .url-drawer.open .url-drawer-content > :global(:nth-child(5)) { transition-delay: 172ms; }
  .url-drawer.open .url-drawer-content > :global(:nth-child(n + 6)) { transition-delay: 200ms; }

  @media (prefers-reduced-motion: reduce) {
    .url-drawer,
    .url-drawer.open,
    .url-drawer-content > :global(*),
    .url-drawer.open .url-drawer-content > :global(*) {
      transition: none;
    }
  }
</style>
