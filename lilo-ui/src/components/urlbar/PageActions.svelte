<!-- With the address hidden, the page's buttons wait behind this one on the top line, so they never crowd the
     history buttons or Agents; the row they open hangs from it. -->
<script lang="ts">
  import type { Snippet } from "svelte";
  import { dismissable } from "../../lib/actions/dismissable";
  import { portal } from "../../lib/actions/portal";
  import { tooltip } from "../../lib/tooltip";
  import { t } from "../../lib/i18n/state.svelte";

  let { children }: { children: Snippet } = $props();

  let button: HTMLButtonElement | undefined = $state();
  let at: { top: number; right: number } | null = $state(null);

  function toggle() {
    const rect = button?.getBoundingClientRect();
    at = at || !rect ? null : { top: rect.bottom + 6, right: window.innerWidth - rect.right };
  }
</script>

<button
  bind:this={button}
  class="page-actions-btn"
  class:open={!!at}
  aria-label={t("urlToast.pageActions")}
  aria-expanded={!!at}
  use:tooltip={{ text: t("urlToast.pageActions"), placement: "bottom", disabled: !!at }}
  onclick={toggle}
>
  <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
    <circle cx="3.5" cy="8" r="1.25" /><circle cx="8" cy="8" r="1.25" /><circle cx="12.5" cy="8" r="1.25" />
  </svg>
</button>

{#if at && button}
  <!-- Keeps the bar's class: the screenshot and extension menus hang from it. -->
  <div
    class="url-trigger actions-only float-surface"
    style="top: {at.top}px; right: {at.right}px"
    use:portal
    {@attach dismissable({
      onDismiss: () => (at = null),
      ignore: ".page-actions-btn, .screenshot-menu, .extensions-popover",
      escape: true,
      returnFocus: button,
    })}
  >
    {@render children()}
  </div>
{/if}

<style>
  .page-actions-btn {
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .page-actions-btn:hover,
  .page-actions-btn.open {
    background: var(--bg-hover);
  }

  .page-actions-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .url-trigger {
    position: fixed;
    z-index: var(--z-popover);
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px;
  }

  /* Every button shows in line: more specific than the address bar's hover and open-menu reveal rules. */
  .url-trigger.actions-only.float-surface :global(.url-actions),
  .url-trigger.actions-only.float-surface :global(.url-actions .url-actions-reveal) {
    position: static;
    gap: 4px;
    transform: none;
    opacity: 1;
    pointer-events: auto;
  }
</style>
