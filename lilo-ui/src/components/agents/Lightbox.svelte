<script lang="ts">
  import { untrack } from "svelte";
  import { cubicOut } from "svelte/easing";
  import { fade, scale } from "svelte/transition";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import Icon from "./Icon.svelte";
  import type { ImageRef } from "./conversationModel";

  interface Props {
    /** Every picture of the conversation, in thread order. */
    images: ImageRef[];
    start: number;
    onclose: () => void;
  }

  let { images, start, onclose }: Props = $props();

  let index = $state(untrack(() => start));
  const image = $derived(images[index]);
  const still = prefersReducedMotion();
  let dialog: HTMLDivElement | undefined = $state();

  $effect(() => dialog?.focus());

  function step(by: number): void {
    index = (index + by + images.length) % images.length;
  }

  function onkeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") onclose();
    else if (event.key === "ArrowLeft" && images.length > 1) step(-1);
    else if (event.key === "ArrowRight" && images.length > 1) step(1);
    else return;
    // The thread and the window's own Escape handlers stay out of it while the viewer is open.
    event.preventDefault();
    event.stopPropagation();
  }
</script>

<div
  class="lightbox"
  role="dialog"
  aria-modal="true"
  aria-label={image.alt || t("agents.image.viewer")}
  tabindex="-1"
  bind:this={dialog}
  {onkeydown}
  onclick={(event) => {
    if (!(event.target as Element).closest("img, button")) onclose();
  }}
  transition:fade={{ duration: still ? 0 : MOTION.itemEnterMs }}
>
  {#key index}
    <img src={image.src} alt={image.alt} decoding="async" in:scale={{ start: 0.97, duration: still ? 0 : MOTION.itemEnterMs, easing: cubicOut }} />
  {/key}
  <button type="button" class="control close" aria-label={t("common.close")} onclick={onclose}><Icon name="close" size={14} /></button>
  {#if images.length > 1}
    <button type="button" class="control previous" aria-label={t("agents.image.previous")} onclick={() => step(-1)}>
      <Icon name="chevronLeft" size={16} />
    </button>
    <button type="button" class="control next" aria-label={t("agents.image.next")} onclick={() => step(1)}>
      <Icon name="chevronRight" size={16} />
    </button>
    <span class="counter">{t("agents.image.counter", { index: index + 1, total: images.length })}</span>
  {/if}
</div>

<style>
  .lightbox {
    position: absolute;
    inset: 0;
    z-index: 10;
    display: grid;
    place-items: center;
    padding: var(--space-32) 56px;
    background: var(--chrome-overlay-backdrop-tint);
    backdrop-filter: blur(var(--chrome-overlay-backdrop-blur));
    outline: none;
  }

  img {
    grid-area: 1 / 1;
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-md);
    background: var(--bg-primary);
    user-select: none;
  }

  .control {
    position: absolute;
    display: grid;
    place-items: center;
    width: var(--control-height-md);
    height: var(--control-height-md);
    padding: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: var(--bg-elevated);
    box-shadow: var(--shadow-sm);
    color: var(--text-primary);
    cursor: pointer;
    transition: transform var(--motion-duration-fast) var(--motion-ease-standard);
  }

  .control:hover {
    background: var(--bg-hover);
  }

  .control:active {
    transform: scale(0.95);
  }

  .control:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .close {
    top: var(--space-12);
    right: var(--space-12);
  }

  .previous,
  .next {
    top: 50%;
    margin-top: calc(var(--control-height-md) / -2);
  }

  .previous {
    left: var(--space-12);
  }

  .next {
    right: var(--space-12);
  }

  .counter {
    position: absolute;
    bottom: var(--space-12);
    left: 50%;
    transform: translateX(-50%);
    padding: var(--space-2) var(--space-10);
    border-radius: var(--radius-chip);
    background: var(--bg-elevated);
    box-shadow: var(--shadow-sm);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }
</style>
