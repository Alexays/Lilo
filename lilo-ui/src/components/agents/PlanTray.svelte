<script lang="ts">
  import { cubicOut } from "svelte/easing";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { restingFly } from "../../lib/motion/restingTransitions";
  import { MOTION } from "../../lib/motion/timings";
  import Icon from "../ui/Icon.svelte";
  import type { PlanEntry } from "./conversationModel";

  interface Props {
    entries: PlanEntry[];
    /** Over the composer, joined to it; in the thread, a box of its own. */
    docked?: boolean;
  }

  let { entries, docked = true }: Props = $props();

  let expanded = $state(false);
  const done = $derived(entries.filter((entry) => entry.status === "completed").length);
  // The step under way, else the next one: what the collapsed tray says the agent is on.
  const current = $derived(entries.find((entry) => entry.status === "in_progress") ?? entries.find((entry) => entry.status === "pending"));
</script>

<div class="plan-tray" class:docked in:restingFly={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs, easing: cubicOut, x: 0, y: 8 }}>
  <button type="button" class="plan-summary" aria-expanded={expanded} onclick={() => (expanded = !expanded)}>
    <svg class="chevron" class:open={expanded} width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
      <path d="M3.5 2l3 3-3 3" stroke="currentColor" fill="none" stroke-width="1.4" stroke-linecap="round" />
    </svg>
    {#if current}
      <span class="progress" style:--plan-done="{(done / entries.length) * 100}%" aria-hidden="true"></span>
    {:else}
      <span class="finished-mark" aria-hidden="true"><Icon name="check" size={12} /></span>
    {/if}
    {#if current}
      <span class="current">{current.content}</span>
      <span class="count">{t("agents.conversation.planProgress", { done, total: entries.length })}</span>
    {:else}
      <span class="current finished">{t("agents.conversation.planDone", { count: done })}</span>
    {/if}
  </button>
  <div class="expand" class:open={expanded} inert={!expanded}>
    <div class="expand-clip">
      <ul class="entries">
        {#each entries as entry, index (index)}
          <li class="entry {entry.status}">
            <span class="box" aria-hidden="true">{#if entry.status === "completed"}<Icon name="check" size={12} />{/if}</span>
            <span>{entry.content}</span>
            <span class="visually-hidden">{t(`agents.conversation.planStatus.${entry.status}`)}</span>
          </li>
        {/each}
      </ul>
    </div>
  </div>
</div>

<style>
  .plan-tray {
    --plan-surface: var(--bg-primary);
    box-sizing: border-box;
    border: 1px solid var(--border);
    border-radius: var(--radius-md);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  /* In the thread, a row like the work around it: no box, the same height, hover and inset. */
  .plan-tray:not(.docked) {
    align-self: flex-start;
    max-width: 100%;
    border: 0;
  }

  .plan-tray:not(.docked) .plan-summary {
    width: auto;
    max-width: 100%;
    height: var(--control-height-sm);
    padding: 0 var(--space-8) 0 var(--space-6);
    margin-left: calc(-1 * var(--space-6));
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    gap: var(--space-6);
  }

  .plan-tray:not(.docked) .current {
    flex: 0 1 auto;
    color: inherit;
  }

  .plan-tray:not(.docked) .plan-summary:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .plan-tray:not(.docked) .entries {
    padding-left: calc(var(--space-6) + 16px);
  }

  .finished-mark {
    flex: none;
    display: inline-flex;
    color: var(--text-muted);
  }

  .plan-tray.docked {
    --plan-surface: var(--bg-secondary);
    width: calc(100% - 2 * var(--space-20));
    border-bottom: 0;
    border-radius: var(--radius-md) var(--radius-md) 0 0;
    background: var(--bg-secondary);
  }

  .plan-summary {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    width: 100%;
    min-width: 0;
    padding: var(--space-6) var(--space-10);
    border: 0;
    border-radius: inherit;
    background: none;
    color: inherit;
    font: inherit;
    text-align: start;
  }

  .plan-summary:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .chevron {
    flex: none;
    color: var(--text-muted);
    transition: transform var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .chevron.open {
    transform: rotate(90deg);
  }

  @property --plan-done {
    syntax: "<percentage>";
    inherits: false;
    initial-value: 0%;
  }

  /* The share of steps done, as the context gauge draws its share. */
  .progress {
    flex: none;
    width: 12px;
    height: 12px;
    border-radius: var(--radius-chip);
    background: conic-gradient(var(--agents) 0 var(--plan-done), var(--text-primary-tint-12) var(--plan-done) 100%);
    mask: radial-gradient(circle, transparent 3.5px, black 4px);
    transition: --plan-done var(--motion-duration-slow) var(--motion-ease-organic);
  }

  .current {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    color: var(--text-primary);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .current.finished {
    color: inherit;
  }

  .count {
    flex: none;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .expand {
    display: grid;
    grid-template-rows: 0fr;
    opacity: 0;
    transition:
      grid-template-rows var(--motion-duration-fast) var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease;
  }

  .expand.open {
    grid-template-rows: 1fr;
    opacity: 1;
    transition-duration: var(--motion-duration-overlay), var(--motion-duration-normal);
  }

  .expand-clip {
    min-height: 0;
    overflow: hidden;
  }

  .entries {
    max-height: 180px;
    margin: 0;
    padding: 0 var(--space-10) var(--space-10) calc(var(--space-10) + 18px);
    overflow-y: auto;
    list-style: none;
  }

  .entry {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-height: 24px;
  }

  .entry.in_progress {
    color: var(--text-primary);
  }

  .entry.completed {
    color: var(--text-muted);
  }

  .box {
    flex: none;
    display: grid;
    place-items: center;
    width: 12px;
    height: 12px;
    box-sizing: border-box;
    border-radius: var(--radius-xs);
    border: 1.5px solid var(--text-muted);
  }

  .entry.in_progress .box {
    border-color: var(--agents);
    background: var(--agents);
    box-shadow: inset 0 0 0 2px var(--plan-surface);
  }

  .entry.completed .box {
    border: 0;
    color: var(--text-secondary);
  }

  .visually-hidden {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
</style>
