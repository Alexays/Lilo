<!-- A calendar event about to start: join it from the link the event carries, or dismiss it. Above the call card. -->
<script lang="ts">
  import { fade, slide } from "svelte/transition";
  import { meetingActions } from "../../lib/bridge/actions";
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { tooltip } from "../../lib/tooltip";
  import { getMeeting } from "../../stores/meeting.svelte";

  const meeting = $derived(getMeeting());
  let now = $state(Date.now());
  const minutes = $derived(meeting ? Math.ceil((meeting.start - now) / 60_000) : 0);
  const format = $derived(new Intl.RelativeTimeFormat(getFormatLocale(), { numeric: "auto", style: "long" }));
  const when = $derived(minutes === 0 ? t("meetingCard.now") : format.format(minutes, "minute"));

  // Wakes only when the shown minute changes, and only while a card is up.
  $effect(() => {
    if (!meeting) return;
    const start = meeting.start;
    let timer: ReturnType<typeof setTimeout>;
    const tick = () => {
      now = Date.now();
      timer = setTimeout(tick, ((start - now) % 60_000 + 60_000) % 60_000 || 60_000);
    };
    tick();
    return () => clearTimeout(timer);
  });

  function reveal(node: Element) {
    return prefersReducedMotion() ? fade(node, { duration: 150 }) : slide(node, { duration: 240 });
  }
</script>

{#if meeting}
  <div class="meeting-dock" transition:reveal>
    <div class="meeting-card">
      <svg class="meeting-icon" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" aria-hidden="true">
        <rect x="2" y="3" width="12" height="11" rx="2.5" />
        <path d="M2 6.5h12M5.5 1.8v2.4M10.5 1.8v2.4" />
      </svg>
      <span class="meeting-text">
        <span class="meeting-title">{meeting.title || t("meetingCard.untitled")}</span>
        <span class="meeting-when">{when}</span>
      </span>
      {#if meeting.url}
        <button
          class="meeting-join"
          aria-label={t("meetingCard.joinLabel", { title: meeting.title || t("meetingCard.untitled") })}
          onclick={() => meetingActions.join(meeting.id)}
        >
          {t("meetingCard.join")}
        </button>
      {/if}
      <button
        class="meeting-close"
        aria-label={t("meetingCard.dismiss")}
        use:tooltip={t("meetingCard.dismiss")}
        onclick={() => meetingActions.dismiss(meeting.id)}
      >
        <svg width="8" height="8" viewBox="0 0 8 8" aria-hidden="true">
          <path d="M1 1l6 6M7 1L1 7" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
        </svg>
      </button>
    </div>
  </div>
{/if}

<style>
  .meeting-dock {
    flex-shrink: 0;
    margin: 0 var(--sidebar-right-pad, 8px) 6px 8px;
  }

  /* A tab strip opens it in a popover, whose padding keeps room for the close button. */
  :global(.strip-popover) .meeting-dock {
    margin: 0;
  }

  .meeting-card {
    position: relative;
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 52px;
    box-sizing: border-box;
    padding: 8px 10px;
    border-radius: var(--radius-md);
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
  }

  .meeting-icon {
    flex-shrink: 0;
    color: var(--accent-ink);
  }

  .meeting-text {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
  }

  .meeting-title {
    overflow: hidden;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .meeting-when {
    overflow: hidden;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .meeting-join {
    flex-shrink: 0;
    height: var(--control-height-md);
    padding: 0 12px;
    border: none;
    border-radius: var(--radius-chip);
    background: var(--accent);
    color: var(--accent-text);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .meeting-join:hover {
    background: var(--accent-hover);
  }

  .meeting-join:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .meeting-close {
    position: absolute;
    top: -6px;
    right: -6px;
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    padding: 0;
    border: 1px solid var(--border);
    border-radius: 50%;
    background: var(--bg-elevated);
    color: var(--text-secondary);
    opacity: 0;
    cursor: pointer;
    transition: opacity var(--transition-fast);
  }

  .meeting-card:hover .meeting-close,
  .meeting-close:focus-visible {
    opacity: 1;
  }

  .meeting-close:hover {
    color: var(--text-primary);
  }

  .meeting-close:focus-visible {
    outline: var(--focus-outline);
  }
</style>
