<!-- The undo toast: a capsule at the bottom center of the page with what just went and a named way
     back, gone after its countdown. Escape stays with the other overlays: it leaves on its action,
     its timeout, or the next toast. -->
<script lang="ts">
  import { fade } from "svelte/transition";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import {
    getUndoToast,
    pauseUndoToast,
    resumeUndoToast,
    undoTabClose,
    undoToastSubject,
    UNDO_TOAST_DURATION_MS,
  } from "../../stores/undoToast.svelte";

  const toast = $derived(getUndoToast());
</script>

<div class="undo-area" class:sidebar-hidden={!isSidebarVisible()}>
  {#if toast}
    <!-- Keyed so a replacement rises in again and its ring restarts from full. -->
    {#key toast.seq}
      <div
        class="undo-toast"
        role="group"
        style={`--undo-duration: ${UNDO_TOAST_DURATION_MS}ms`}
        use:reportInteractiveZone={{ id: "undo-toast" }}
        onmouseenter={pauseUndoToast}
        onmouseleave={resumeUndoToast}
        onfocusin={pauseUndoToast}
        onfocusout={resumeUndoToast}
        out:fade={{ duration: prefersReducedMotion() ? 150 : 120 }}
      >
        <svg class="undo-ring" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
          <circle class="track" cx="8" cy="8" r="6.5" />
          <circle class="remaining" cx="8" cy="8" r="6.5" />
        </svg>
        <span class="undo-subject">{undoToastSubject(toast)}</span>
        <button
          class="undo-action"
          type="button"
          use:tooltip={{ text: undoToastSubject(toast), shortcut: toast.archivedIds || toast.undo ? undefined : shortcutKeys("tab.reopenClosed") }}
          onclick={undoTabClose}
        >
          {t(toast.undo ? "undoToast.undo" : "undoToast.reopen")}
        </button>
      </div>
    {/key}
  {/if}
</div>

<style>
  .undo-area {
    position: fixed;
    left: var(--chrome-content-left-visible);
    right: var(--chrome-content-right);
    bottom: calc(var(--chrome-content-bottom) + 24px);
    /* One cell: a replacement rises in over the one fading out. */
    display: grid;
    justify-items: center;
    padding: 0 24px;
    pointer-events: none;
    z-index: var(--z-popover);
  }

  .undo-area.sidebar-hidden {
    left: var(--chrome-content-left-hidden);
  }

  /* Inverted from the floating cards, as macOS draws a passing notice. */
  .undo-toast {
    grid-area: 1 / 1;
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
    max-width: 560px;
    height: 40px;
    padding: 0 6px 0 14px;
    border-radius: var(--radius-chip);
    background: var(--float-text);
    color: var(--float-surface);
    box-shadow: var(--float-shadow);
    font-size: var(--font-size-md);
    pointer-events: auto;
    animation: undo-rise var(--motion-duration-normal) var(--motion-ease-spring) both;
  }

  @keyframes undo-rise {
    from {
      transform: translateY(8px);
      opacity: 0;
    }
  }

  .undo-subject {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .undo-action {
    flex: none;
    height: 28px;
    padding: 0 12px;
    border: 0;
    border-radius: var(--radius-chip);
    background: color-mix(in srgb, var(--float-surface) 18%, transparent);
    color: inherit;
    font-family: inherit;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
  }

  .undo-action:hover {
    background: color-mix(in srgb, var(--float-surface) 28%, transparent);
  }

  .undo-action:focus-visible {
    outline: 2px solid var(--float-surface);
    outline-offset: 1px;
  }

  /* Drains clockwise from 12 o'clock. */
  .undo-ring {
    flex: none;
    transform: rotate(-90deg);
  }

  .undo-ring circle {
    fill: none;
    stroke: currentColor;
    stroke-width: 2;
  }

  .undo-ring .track {
    opacity: 0.25;
  }

  .undo-ring .remaining {
    stroke-linecap: round;
    stroke-dasharray: 40.85;
    animation: undo-countdown var(--undo-duration) linear forwards;
  }

  /* Mirrors the store's hover and focus pause so the ring and the timer never disagree. */
  .undo-toast:hover .remaining,
  .undo-toast:focus-within .remaining {
    animation-play-state: paused;
  }

  @keyframes undo-countdown {
    to {
      stroke-dashoffset: 40.85;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .undo-toast {
      animation: undo-fade 150ms ease both;
    }
  }

  @keyframes undo-fade {
    from {
      opacity: 0;
    }
  }
</style>
