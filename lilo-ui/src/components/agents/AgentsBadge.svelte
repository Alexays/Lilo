<!-- The one entry point to Agents in the chrome: the mascot, a ring while agents work, an orange dot while
     one waits on you. It opens the list of every conversation, across Spaces, starting with New, or New itself when there is none. -->
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
  <!-- Keyed on the count, so each new wait pops the dot again; the count itself is in the label. -->
  {#key waiting}
    <span
      class="dot"
      hidden={waiting === 0}
      aria-hidden="true"
      in:scale={{ start: 0.4, duration: prefersReducedMotion() ? 0 : 260, easing: backOut }}
    ></span>
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

  /* In the address field, where a narrow sidebar moves it, it takes the field's 24 px buttons. */
  :global(.field-agents) .agents-button {
    width: 24px;
    height: 24px;
  }

  /* The field paints --bg-hover itself, so a hover needs a tint above it. */
  :global(.field-agents) .agents-button:is(:hover, .open) {
    background: var(--text-primary-tint-12);
  }

  /* The waiting dot's ring takes the field's translucent fill, laid over the sidebar's. */
  :global(.field-agents) .dot {
    box-shadow:
      0 0 0 2px var(--bg-hover),
      0 0 0 2px var(--sidebar-bg);
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

  .dot {
    position: absolute;
    top: 3px;
    right: 3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--sidebar-bg);
    pointer-events: none;
  }

  .dot[hidden] {
    display: none;
  }
</style>
