<!-- A downloaded update, fixed above the bottom bar: Restart installs it now, otherwise it installs on quit. -->
<script lang="ts">
  import { slide } from "svelte/transition";
  import { settingsActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { tooltip } from "../../lib/tooltip";
  import { getChosenAppIcon, getReadyUpdate, isRestartingForUpdate, restartForUpdate } from "../../stores/settings.svelte";

  const version = $derived(getReadyUpdate());
  const icon = $derived(getChosenAppIcon());
  const restarting = $derived(isRestartingForUpdate());
</script>

{#if version}
  <div class="update-dock" transition:slide={{ duration: prefersReducedMotion() ? 0 : 240 }}>
    <div class="update-card" class:restarting>
      <button
        class="update-main"
        aria-label={t("updateCard.restartLabel", { version })}
        disabled={restarting}
        onclick={restartForUpdate}
      >
        <span class="update-icon">
          {#if icon}<img src={icon} alt="" width="28" height="28" />{/if}
        </span>
        <span class="update-text">
          <span class="update-title">Lilo <span class="update-version">{version}</span></span>
          <span class="update-sub">{t(restarting ? "updateCard.restarting" : "updateCard.ready")}</span>
        </span>
        {#if restarting}
          <svg class="update-spinner" width="20" height="20" viewBox="0 0 20 20" aria-hidden="true">
            <circle cx="10" cy="10" r="8" />
          </svg>
        {:else}
          <span class="update-go">{t("updateCard.restart")}</span>
        {/if}
      </button>
      {#if !restarting}
        <button
          class="update-close"
          aria-label={t("updateCard.later")}
          use:tooltip={t("updateCard.later")}
          onclick={() => settingsActions.dismissUpdate()}
        >
          <svg width="8" height="8" viewBox="0 0 8 8" aria-hidden="true">
            <path d="M1 1l6 6M7 1L1 7" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
          </svg>
        </button>
      {/if}
    </div>
  </div>
{/if}

<style>
  .update-dock {
    flex-shrink: 0;
    margin: 0 var(--sidebar-right-pad, 10px) 8px 10px;
  }

  /* A tab strip opens it in a popover, whose padding keeps room for the close button. */
  :global(.strip-popover) .update-dock {
    margin: 0;
  }

  @property --update-sweep {
    syntax: "<angle>";
    inherits: false;
    initial-value: 0deg;
  }

  .update-card {
    position: relative;
    padding: 1px;
    border-radius: var(--radius-md);
    isolation: isolate;
    animation: update-rise 520ms var(--motion-ease-bounce) both;
  }

  /* A light runs once around the edge as the card lands, then rests as an accent hairline. */
  .update-card::before {
    content: "";
    position: absolute;
    inset: 0;
    z-index: -1;
    border-radius: inherit;
    background:
      conic-gradient(
        from var(--update-sweep),
        transparent 0 62%,
        color-mix(in srgb, var(--accent) 80%, white) 78%,
        var(--tile-lilo) 86%,
        transparent 94%
      ),
      var(--accent-tint-22);
    animation: update-sweep 1.6s var(--motion-ease-spring) 250ms both;
  }

  .update-main {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 7px 8px 7px 8px;
    border: none;
    border-radius: calc(var(--radius-md) - 1px);
    background:
      radial-gradient(120% 140% at 0% 0%, var(--accent-tint-14), transparent 60%),
      var(--bg-selected);
    color: var(--text-primary);
    font-family: inherit;
    text-align: left;
    cursor: pointer;
  }

  .update-main:disabled {
    cursor: default;
  }

  .update-main:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .update-icon {
    position: relative;
    flex-shrink: 0;
    width: 28px;
    height: 28px;
    overflow: hidden;
    border-radius: var(--radius-sm);
    animation: update-pop 640ms var(--motion-ease-bounce) 120ms both;
  }

  .update-icon img {
    display: block;
    width: 100%;
    height: 100%;
  }

  .update-icon::after {
    content: "";
    position: absolute;
    inset: -40%;
    background: linear-gradient(115deg, transparent 40%, color-mix(in srgb, white 55%, transparent) 50%, transparent 60%);
    transform: translateX(-100%);
    animation: update-shine 1.1s ease 900ms;
  }

  .restarting .update-icon img {
    animation: update-breathe 1.2s var(--motion-ease-standard) infinite alternate;
  }

  .update-text {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
  }

  .update-title {
    display: flex;
    align-items: baseline;
    gap: 6px;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
  }

  .update-version {
    padding: 1px 6px;
    border-radius: var(--radius-chip);
    background: var(--accent-tint-14);
    color: var(--accent-ink);
    font-size: var(--font-size-2xs);
  }

  .update-sub {
    overflow: hidden;
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .update-go {
    flex-shrink: 0;
    padding: 4px 10px;
    border-radius: var(--radius-chip);
    background: var(--accent);
    color: var(--accent-text);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    box-shadow: var(--shadow-control), inset 0 1px 0 color-mix(in srgb, white 25%, transparent);
    transition:
      background var(--transition-fast),
      transform 160ms var(--motion-ease-spring);
  }

  .update-main:hover .update-go {
    background: var(--accent-hover);
  }

  .update-main:active .update-go {
    transform: scale(0.95);
  }

  .update-spinner {
    flex-shrink: 0;
    margin-right: 4px;
    animation: update-spin 0.9s linear infinite;
  }

  .update-spinner circle {
    fill: none;
    stroke: var(--accent);
    stroke-width: 2.2;
    stroke-linecap: round;
    stroke-dasharray: 32 18;
  }

  .update-close {
    position: absolute;
    top: -6px;
    right: -6px;
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    padding: 0;
    border: 1px solid var(--border);
    border-radius: 50%;
    background: var(--bg-elevated);
    color: var(--text-secondary);
    opacity: 0;
    transform: scale(0.6);
    cursor: pointer;
    transition:
      opacity var(--transition-fast),
      transform 200ms var(--motion-ease-spring);
  }

  .update-card:hover .update-close,
  .update-close:focus-visible {
    opacity: 1;
    transform: none;
  }

  .update-close:hover {
    color: var(--text-primary);
  }

  .update-close:focus-visible {
    outline: var(--focus-outline);
  }

  @keyframes update-rise {
    from {
      transform: translateY(14px) scale(0.96);
      opacity: 0;
    }
  }

  @keyframes update-sweep {
    from {
      --update-sweep: 0deg;
    }
    to {
      --update-sweep: 360deg;
    }
  }

  @keyframes update-pop {
    from {
      transform: scale(0.3) rotate(-30deg);
      opacity: 0;
    }
  }

  @keyframes update-shine {
    to {
      transform: translateX(100%);
    }
  }

  @keyframes update-breathe {
    to {
      transform: scale(0.88);
    }
  }

  @keyframes update-spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
