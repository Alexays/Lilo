<script lang="ts">
  import type { Snippet } from "svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { getTabPosition } from "../../stores/tabLayout.svelte";

  let { anchor, label, onclose, children }: { anchor: HTMLElement; label: string; onclose: () => void; children: Snippet } = $props();

  let popover: HTMLDivElement | undefined = $state();
  let height = $state(0);
  const rect = $derived(anchor.getBoundingClientRect());
  // Toward the page, clear of the strip itself: under a top strip, over a bottom dock.
  const strip = $derived((anchor.closest(".tab-strip") ?? anchor).getBoundingClientRect());
  const top = $derived(getTabPosition() === "bottom" ? strip.top - 8 - height : strip.bottom + 4);
  const left = $derived(Math.max(8, Math.min(rect.left, window.innerWidth - 248)));

  $effect(() => {
    popover?.querySelector<HTMLElement>("button")?.focus({ preventScroll: true });
    const dismiss = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!popover?.contains(target) && !anchor.contains(target)) onclose();
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.stopPropagation();
      onclose();
      anchor.focus();
    };
    window.addEventListener("pointerdown", dismiss, true);
    window.addEventListener("keydown", escape, true);
    return () => {
      window.removeEventListener("pointerdown", dismiss, true);
      window.removeEventListener("keydown", escape, true);
    };
  });
</script>

<div
  bind:this={popover}
  bind:clientHeight={height}
  class="strip-popover"
  role="menu"
  aria-label={label}
  style={`left: ${left}px; top: ${top}px;`}
  use:reportInteractiveZone={{ id: "strip-popover" }}
>
  {@render children()}
</div>

<style>
  .strip-popover {
    position: fixed;
    z-index: 60;
    width: 240px;
    max-height: 60vh;
    overflow-y: auto;
    padding: 6px;
    box-sizing: border-box;
    border-radius: 12px;
    background: var(--chrome-overlay-surface-strong);
    box-shadow: var(--chrome-overlay-shadow, 0 14px 36px rgba(0, 0, 0, 0.18));
    pointer-events: auto;
    animation: popover-in 180ms var(--motion-ease-spring) both;
  }

  @keyframes popover-in {
    from {
      opacity: 0;
      transform: scale(0.97);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .strip-popover {
      animation: none;
    }
  }
</style>
