<!-- A conversation's agent icon with its state as a badge on the corner, never in its place; the orange
     dot arrives with one soft pop. -->
<script lang="ts">
  import { backOut } from "svelte/easing";
  import { fade, scale } from "svelte/transition";
  import AgentTile from "./AgentTile.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";

  let {
    agentId,
    waiting,
    busy,
    failed,
    unread,
  }: { agentId: string; waiting: boolean; busy: boolean; failed: boolean; unread: boolean } = $props();
</script>

<span class="icon">
  <AgentTile {agentId} />
  {#if waiting}
    <span
      class="badge attention"
      aria-hidden="true"
      in:scale={{ start: 0.3, duration: prefersReducedMotion() ? 0 : 360, easing: backOut }}
      out:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}
    ></span>
  {:else if busy}
    <span class="badge spinner" aria-hidden="true" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
  {:else if failed}
    <span class="badge failed" aria-hidden="true" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
  {:else if unread}
    <span class="badge unread" aria-hidden="true" transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}></span>
  {/if}
</span>

<style>
  .icon {
    position: relative;
    flex: none;
    display: grid;
    width: 16px;
    height: 16px;
  }

  /* Ringed in the sidebar colour so it reads on any icon. */
  .badge {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    box-shadow: 0 0 0 2px var(--sidebar-bg);
  }

  .badge.attention {
    background: var(--attention);
  }

  .badge.failed {
    background: var(--danger);
  }

  .badge.unread {
    background: var(--accent);
  }

  /* About 30 s of turns, then a still arc: a turn left running must not keep the display link up. */
  .badge.spinner {
    width: 8px;
    height: 8px;
    right: -4px;
    bottom: -4px;
    box-sizing: border-box;
    border: 1.5px solid var(--text-primary-tint-12);
    border-top-color: var(--agents);
    border-right-color: var(--agents);
    background: var(--sidebar-bg);
    animation: conversation-spin 0.9s linear 33 forwards;
  }

  @keyframes conversation-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .badge.spinner {
      animation: none;
    }
  }
</style>
