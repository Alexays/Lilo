<script lang="ts">
  import type { Snippet } from "svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { dismissable } from "../../lib/actions/dismissable";
  import { menuKeys } from "../../lib/actions/menuKeys";
  import { portal } from "../../lib/actions/portal";
  import { popoverOut } from "../../lib/motion/restingTransitions";
  import { getTabPosition } from "../../stores/tabLayout.svelte";

  // A menu's rows are `menuitem`s the arrows walk; a card, a palette or a form is a `dialog`.
  let { anchor, label, role = "menu", onclose, children }: {
    anchor: HTMLElement;
    label: string;
    role?: "menu" | "dialog";
    onclose: () => void;
    children: Snippet;
  } = $props();

  let popover: HTMLDivElement | undefined = $state();
  let height = $state(0);
  const rect = $derived(anchor.getBoundingClientRect());
  // Toward the page, clear of the strip itself: under a top strip, over a bottom dock or an anchor with no room below.
  const strip = $derived((anchor.closest(".tab-strip") ?? anchor).getBoundingClientRect());
  const above = $derived(getTabPosition() === "bottom" || strip.bottom + 4 + height > window.innerHeight - 8);
  // Beside a vertical rail it opens toward the page, level with its anchor.
  const rail = $derived(anchor.closest(".sidebar-rail")?.getBoundingClientRect());
  const top = $derived(Math.max(8, Math.min(
    rail ? rect.top : above ? strip.top - 8 - height : strip.bottom + 4,
    window.innerHeight - height - 8,
  )));
  const left = $derived(rail
    ? getTabPosition() === "right" ? rail.left - 8 - 240 : rail.right + 8
    : Math.max(8, Math.min(rect.left, window.innerWidth - 248)));
  // Grows from its anchor, so it reads as coming out of the button.
  const origin = $derived(rail
    ? `${getTabPosition() === "right" ? "right" : "left"} ${rect.height / 2}px`
    : `${Math.max(0, Math.min(240, rect.left + rect.width / 2 - left))}px ${above ? "bottom" : "top"}`);

  $effect(() => {
    popover?.querySelector<HTMLElement>("button")?.focus({ preventScroll: true });
  });

  // A press outside, a click in the page or Escape closes it; the opener's own press toggles it instead.
  const dismiss = $derived(dismissable({ onDismiss: onclose, ignore: `[aria-expanded="true"]`, escape: true, returnFocus: anchor }));
</script>

<div
  bind:this={popover}
  bind:clientHeight={height}
  class="strip-popover float-surface float-popover"
  {role}
  aria-label={label}
  style={`left: ${left}px; top: ${top}px; transform-origin: ${origin};`}
  out:popoverOut|global
  use:portal
  use:reportInteractiveZone={{ id: "strip-popover" }}
  {@attach dismiss}
  {@attach role === "menu" && menuKeys}
>
  {@render children()}
</div>

<style>
  /* Its menus stack their rows flush. */
  .strip-popover {
    position: fixed;
    z-index: var(--z-popover);
    display: block;
    width: 240px;
    max-height: 60vh;
    overflow-y: auto;
    box-sizing: border-box;
    pointer-events: auto;
  }
</style>
