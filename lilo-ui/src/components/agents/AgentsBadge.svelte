<!-- Every conversation at a glance: the mascot and how many wait on you. Shown only while a conversation
     exists; it opens the list of all of them, across Spaces. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { backOut } from "svelte/easing";
  import { scale } from "svelte/transition";
  import AgentMascot from "../sidebar/AgentMascot.svelte";
  import AgentsPopover from "./AgentsPopover.svelte";
  import { conversationActions } from "./conversationActions";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { tooltip } from "../../lib/tooltip";
  import { getConversationSummaries, getWaitingCount } from "../../stores/conversations.svelte";

  $effect(() => {
    conversationActions.loadSummaries();
  });

  const summaries = $derived(getConversationSummaries());
  const waiting = $derived(getWaitingCount());
  const working = $derived(summaries.some((summary) => summary.state === "busy" || summary.state === "starting"));
  const label = $derived(waiting > 0 ? t("agents.badge.waiting", { count: waiting }) : t("agents.badge.title"));

  let open = $state(false);
  let pill: HTMLButtonElement | undefined = $state();
</script>

{#if summaries.length > 0}
  <button
    bind:this={pill}
    class="agents-pill"
    class:waiting={waiting > 0}
    class:open
    aria-label={label}
    aria-expanded={open}
    use:tooltip={{ text: label, placement: "bottom", disabled: open }}
    onclick={() => (open = !open)}
  >
    <!-- The still glyph at rest: the animated mascot blinks on a timer, only worth it while agents work. -->
    {#if waiting > 0 || working}
      <span class="mascot"><AgentMascot mood={waiting > 0 ? "waitingForUser" : "working"} /></span>
    {:else}
      <svg class="glyph" width="14" height="14" viewBox="0 0 22 22" aria-hidden="true">
        <circle class="glyph-body" cx="11" cy="11" r="9.25" />
        <ellipse class="glyph-eye" cx="7.5" cy="10" rx="1.8" ry="2.3" />
        <ellipse class="glyph-eye" cx="14.5" cy="10" rx="1.8" ry="2.3" />
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

  {#if open && pill}
    <AgentsPopover anchor={pill} {summaries} onclose={() => (open = false)} />
  {/if}
{/if}

<style>
  .agents-pill {
    display: flex;
    align-items: center;
    gap: 4px;
    height: 22px;
    padding: 0 6px 0 4px;
    border: none;
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-bold);
    font-variant-numeric: tabular-nums;
    cursor: pointer;
    transition:
      background var(--transition-fast),
      box-shadow var(--transition-fast);
  }

  .agents-pill:not(.waiting) {
    padding: 0 4px;
  }

  .agents-pill:hover,
  .agents-pill.open {
    background: var(--text-primary-tint-12);
  }

  .agents-pill.waiting {
    background: color-mix(in srgb, var(--attention) 22%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--attention) 50%, transparent);
  }

  .agents-pill.waiting:hover,
  .agents-pill.waiting.open {
    background: color-mix(in srgb, var(--attention) 34%, transparent);
  }

  .agents-pill:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  /* AgentMascot draws at 18px: brought down to the glyph's 14px. */
  .mascot {
    display: grid;
    place-items: center;
    width: 14px;
    height: 14px;
    scale: 0.78;
  }

  .glyph-body {
    fill: white;
    stroke: var(--agents);
    stroke-width: 1.5;
  }

  .glyph-eye {
    fill: var(--agents);
  }
</style>
