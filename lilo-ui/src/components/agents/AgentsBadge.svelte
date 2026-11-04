<!-- The one entry point to Agents in the chrome: the mascot, a ring while agents work, an orange count for
     those waiting on you. It opens the list of every conversation, across Spaces, starting with New, or New itself when there is none. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { backOut } from "svelte/easing";
  import { scale } from "svelte/transition";
  import AgentsPopover from "./AgentsPopover.svelte";
  import MascotGlyph from "./MascotGlyph.svelte";
  import { conversationActions } from "./conversationActions";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { tooltip } from "../../lib/tooltip";
  import { getConversationSummaries, getWaitingCount, openAskBar } from "../../stores/conversations.svelte";

  $effect(() => {
    conversationActions.loadSummaries();
  });

  const summaries = $derived(getConversationSummaries());
  const waiting = $derived(getWaitingCount());
  const working = $derived(summaries.some((summary) => summary.state === "busy" || summary.state === "starting"));
  const label = $derived(waiting > 0 ? t("agents.badge.waiting", { count: waiting }) : t("agents.badge.title"));

  // The popover's own filter: with nothing it would list, the button starts a conversation instead.
  const listed = $derived(
    summaries.some((s) => s.permission || s.state === "busy" || s.state === "starting" || s.state === "failed" || s.unread || s.title),
  );

  let open = $state(false);
  let button: HTMLButtonElement | undefined = $state();
</script>

<button
  bind:this={button}
  class="agents-button"
  class:open
  aria-label={label}
  aria-expanded={open}
  use:tooltip={{ text: label, placement: "bottom", disabled: open }}
  onclick={() => {
    if (!open && !listed) openAskBar();
    else open = !open;
  }}
>
  <MascotGlyph />
  {#if working}
    <svg class="ring" width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="11" pathLength="100" />
    </svg>
  {/if}
  <!-- Kept in the key block even at zero, so a change pops it but the first draw does not. -->
  {#key waiting}
    <span
      class="count"
      hidden={waiting === 0}
      aria-hidden="true"
      in:scale={{ start: 0.6, duration: prefersReducedMotion() ? 0 : 260, easing: backOut }}
    >{waiting}</span>
  {/key}
</button>

{#if open && button}
  <AgentsPopover anchor={button} {summaries} onclose={() => (open = false)} />
{/if}

<style>
  /* Reload's metrics, so it reads as one of the landmark's buttons. */
  .agents-button {
    position: relative;
    flex: none;
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .agents-button > :global(*) {
    grid-area: 1 / 1;
  }

  .agents-button:hover,
  .agents-button.open {
    background: var(--bg-hover);
  }

  .agents-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .ring {
    overflow: visible;
  }

  /* About 30 s of turns, then a still arc: a turn left running must not keep the display link up. */
  .ring circle {
    fill: none;
    stroke: var(--agents);
    stroke-width: 1.75;
    stroke-linecap: round;
    stroke-dasharray: 30 70;
    transform-origin: center;
    animation: agents-ring-spin 1s linear 30 forwards;
  }

  @keyframes agents-ring-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .ring circle {
      animation: none;
    }
  }

  .count {
    position: absolute;
    top: 0;
    right: 0;
    min-width: 14px;
    height: 14px;
    padding: 0 4px;
    box-sizing: border-box;
    border-radius: var(--radius-chip);
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--sidebar-bg);
    color: var(--attention-text);
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-bold);
    font-variant-numeric: tabular-nums;
    line-height: 14px;
    text-align: center;
  }

  .count[hidden] {
    display: none;
  }
</style>
