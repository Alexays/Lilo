<!-- Undo dock at the bottom of the active space pane, above the extension icons: in flow,
     so it takes its room from the tab list instead of covering or shifting the chrome.
     Escape stays with the other overlays: it only dismisses on Undo, timeout, or replacement. -->
<script lang="ts">
  import { slide } from "svelte/transition";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    getUndoToast,
    pauseUndoToast,
    resumeUndoToast,
    undoTabClose,
    UNDO_TOAST_DURATION_MS,
  } from "../../stores/undoToast.svelte";

  const toast = $derived(getUndoToast());
  const closedLabel = $derived(
    !toast
      ? ""
      : toast.label ??
        (toast.count > 1
          ? t("undoToast.closedCount", { count: toast.count })
          : t("undoToast.closed", { title: toast.title })),
  );
</script>

{#if toast}
  <div class="undo-dock" transition:slide={{ duration: prefersReducedMotion() ? 0 : 200 }}>
    <button
      class="undo-toast"
      aria-label={t("undoToast.undoLabel", { closed: closedLabel })}
      style={`--undo-duration: ${UNDO_TOAST_DURATION_MS}ms`}
      use:reportInteractiveZone={{ id: "undo-toast" }}
      use:tooltip={{ text: closedLabel, shortcut: toast.archivedIds || toast.undo ? undefined : shortcutKeys("tab.reopenClosed") }}
      onmouseenter={pauseUndoToast}
      onmouseleave={resumeUndoToast}
      onfocus={pauseUndoToast}
      onblur={resumeUndoToast}
      onclick={undoTabClose}
    >
      <!-- Remounted on every close so the ring animation restarts from full. -->
      {#key toast.seq}
        <svg class="undo-ring" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
          <circle cx="6" cy="6" r="5" />
        </svg>
      {/key}
      <svg class="undo-arrow" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
        <path
          d="M2.6 4.4H7.4a2.3 2.3 0 0 1 0 4.6H5.6"
          fill="none"
          stroke="currentColor"
          stroke-width="1.3"
          stroke-linecap="round"
        />
        <path
          d="M4.7 2.3 2.4 4.4l2.3 2.1"
          fill="none"
          stroke="currentColor"
          stroke-width="1.3"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
      <span class="undo-label">{t("undoToast.undo")}</span>
    </button>
  </div>
{/if}

<style>
  .undo-dock {
    flex-shrink: 0;
    display: flex;
    justify-content: center;
    margin: 0 8px;
    /* #chrome-root is pointer-events:none; the dock must opt back in to be clickable. */
    pointer-events: auto;
  }

  .undo-toast {
    display: flex;
    align-items: center;
    gap: 4px;
    max-width: 100%;
    padding: 4px 8px 4px 6px;
    border: 1px solid color-mix(in srgb, var(--text-primary) 7%, transparent);
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--bg-hover) 42%, transparent);
    color: var(--accent);
    font-family: inherit;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
    /* Rises out of the bottom bar as the dock unfolds. */
    animation: undo-rise 320ms var(--motion-ease-bounce);
    transition:
      background var(--transition-fast),
      border-color var(--transition-fast);
  }

  .undo-toast:hover {
    background: var(--accent-tint-12);
    border-color: color-mix(in srgb, var(--accent) 24%, transparent);
  }

  @keyframes undo-rise {
    from {
      transform: translateY(10px);
      opacity: 0;
    }
  }

  .undo-ring,
  .undo-arrow {
    flex-shrink: 0;
  }

  /* Drains clockwise from 12 o'clock. */
  .undo-ring {
    transform: rotate(-90deg);
  }

  .undo-ring circle {
    fill: none;
    stroke: currentColor;
    stroke-width: 1.5;
    opacity: 0.5;
    stroke-dasharray: 31.4;
    animation: undo-countdown var(--undo-duration) linear forwards;
  }

  /* Mirrors the store's hover and focus pause so the ring and the timer never disagree. */
  .undo-toast:hover .undo-ring circle,
  .undo-toast:focus .undo-ring circle {
    animation-play-state: paused;
  }

  @keyframes undo-countdown {
    from {
      stroke-dashoffset: 0;
    }
    to {
      stroke-dashoffset: 31.4;
    }
  }

  .undo-label {
    white-space: nowrap;
  }
</style>
