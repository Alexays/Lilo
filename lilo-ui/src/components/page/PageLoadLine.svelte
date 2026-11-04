<script lang="ts">
  import { untrack } from "svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";

  // DESIGN.md: a load shorter than this shows nothing.
  const SHOW_DELAY_MS = 300;
  // The fill to full width, then the fade: the two transitions below, back to back.
  const FINISH_MS = 400;

  const tabId = $derived(getActiveTab()?.id ?? "");
  const loading = $derived(getActiveTab()?.isLoading ?? false);
  const progress = $derived(Math.max(0.08, Math.min(1, getActiveTab()?.progress ?? 0)));

  let shown = $state(false);
  let finishing = $state(false);
  let lastTabId = "";
  let timer: ReturnType<typeof setTimeout> | undefined;

  $effect(() => {
    const id = tabId;
    const isLoading = loading;
    untrack(() => {
      const switched = id !== lastTabId;
      lastTabId = id;
      clearTimeout(timer);
      if (isLoading) {
        shown = false;
        finishing = false;
        timer = setTimeout(() => (shown = true), SHOW_DELAY_MS);
      } else if (shown && !finishing && !switched) {
        finishing = true;
        timer = setTimeout(() => (shown = finishing = false), FINISH_MS);
      } else {
        shown = finishing = false;
      }
    });
  });

  $effect(() => () => clearTimeout(timer));
</script>

<div
  class="page-load-line"
  class:shown
  class:finishing
  style:transform={shown ? `scaleX(${finishing ? 1 : progress})` : "scaleX(0)"}
  aria-hidden="true"
></div>

<style>
  /* Centered in the window inset above the page, over the page's width only. */
  .page-load-line {
    position: fixed;
    top: calc((var(--content-inset) - 2px) / 2);
    left: var(--chrome-content-left);
    right: var(--chrome-content-right);
    width: min(140px, 30vw);
    height: 2px;
    margin: 0 auto;
    border-radius: var(--radius-chip);
    background: var(--sidebar-muted);
    opacity: 0;
    pointer-events: none;
    transition: opacity var(--motion-duration-normal) ease;
  }

  /* Only while shown: hidden, it snaps back to nothing instead of shrinking out of sight. */
  .page-load-line.shown {
    opacity: 1;
    transition:
      transform var(--motion-duration-normal) var(--motion-ease-standard),
      opacity var(--motion-duration-normal) ease;
  }

  .page-load-line.finishing {
    opacity: 0;
    transition:
      transform var(--motion-duration-normal) var(--motion-ease-standard),
      opacity var(--motion-duration-normal) ease var(--motion-duration-normal);
  }

  @media (prefers-reduced-motion: reduce) {
    .page-load-line.shown,
    .page-load-line.finishing {
      transition-property: opacity;
    }
  }
</style>
