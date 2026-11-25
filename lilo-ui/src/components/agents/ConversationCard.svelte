<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { fade } from "svelte/transition";
  import { tabActions } from "../../lib/bridge/actions";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import ConversationView from "./ConversationView.svelte";

  interface Props {
    /** The conversation's own tab, where it expands to. */
    tabId: string;
    onclose: () => void;
  }

  let { tabId, onclose }: Props = $props();

  const FULL_FRAME = { x: 0, y: 0, width: 1, height: 1 };
</script>

<!-- Rises from where the Ask bar was, over the page it answers about, which stays usable around it. -->
<div class="conversation-card-root chrome-content-overlay-root">
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="conversation-card float-surface"
    out:fade={{ duration: prefersReducedMotion() ? 150 : 120 }}
    onkeydown={(event) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      onclose();
    }}
  >
    <ConversationView
      {tabId}
      frame={FULL_FRAME}
      {onclose}
      onexpand={() => {
        onclose();
        tabActions.switchTo(tabId);
      }}
    />
  </div>
</div>

<style>
  .conversation-card-root {
    pointer-events: none;
  }

  .conversation-card {
    position: absolute;
    left: 50%;
    bottom: var(--space-24);
    translate: -50% 0;
    width: min(700px, calc(100% - var(--space-32)));
    height: min(480px, calc(100% - 2 * var(--space-24)));
    border-radius: var(--radius-lg);
    overflow: hidden;
    transform-origin: 50% 100%;
    animation: card-in var(--motion-duration-overlay) var(--motion-ease-spring) both;
  }

  @keyframes card-in {
    from {
      opacity: 0;
      scale: 0.96;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .conversation-card {
      animation: card-fade 150ms linear both;
    }

    @keyframes card-fade {
      from {
        opacity: 0;
      }
    }
  }
</style>
