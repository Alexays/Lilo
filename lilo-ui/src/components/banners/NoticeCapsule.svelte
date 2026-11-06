<!-- The window's notices in one capsule over the top of the page: the first one, and the rest folded
     behind "N more notices" until it is opened. Each notice keeps its own action or close button. -->
<script lang="ts">
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { extensionActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    dismissCrashRecoveryBanner,
    dismissSessionRestoreDegradedBanner,
    getCrashRecoverySeq,
    getDegradedSpaceName,
    getExtensionDebuggers,
  } from "../../stores/banners.svelte";
  import Icon from "../ui/Icon.svelte";
  import UiButton from "../ui/UiButton.svelte";

  interface Notice {
    id: string;
    message: string;
    /** A verb that settles the notice; a notice without one gets a close button. */
    action?: { label: string; run: () => void };
  }

  const crashSeq = $derived(getCrashRecoverySeq());

  // Keyed on the sequence so a repeat event restarts the auto-hide instead of cutting it short.
  $effect(() => {
    if (crashSeq === 0) return;
    const timer = setTimeout(dismissCrashRecoveryBanner, 5000);
    return () => clearTimeout(timer);
  });

  const notices = $derived.by((): Notice[] => {
    const list: Notice[] = [];
    if (crashSeq > 0) list.push({ id: "crash", message: t("crashRecovery.sessionRestored") });
    const spaceName = getDegradedSpaceName();
    // Stays until dismissed: unlike the crash notice, this one reports degraded data.
    if (spaceName !== null) list.push({ id: "degraded", message: t("sessionRestore.degraded", { name: spaceName }) });
    for (const { id, name } of getExtensionDebuggers()) {
      list.push({
        id: `debugger-${id}`,
        message: t("extensionDebugger.message", { name }),
        action: { label: t("extensionDebugger.stop"), run: () => extensionActions.cancelDebugging(id) },
      });
    }
    return list;
  });

  let expanded = $state(false);
  const open = $derived(expanded && notices.length > 1);

  function dismiss(notice: Notice): void {
    if (notice.id === "crash") dismissCrashRecoveryBanner();
    else if (notice.id === "degraded") dismissSessionRestoreDegradedBanner();
  }
</script>

{#snippet trailing(notice: Notice)}
  {#if notice.action}
    <UiButton onclick={notice.action.run}>{notice.action.label}</UiButton>
  {/if}
{/snippet}

{#snippet close(notice: Notice)}
  {#if !notice.action}
    <button class="notice-close" type="button" aria-label={t("common.close")} onclick={() => dismiss(notice)}>
      <Icon name="close" size={14} />
    </button>
  {/if}
{/snippet}

<div class="banner-host chrome-content-overlay-root">
  {#if notices.length > 0}
    {@const [first, ...rest] = notices}
    <!-- The capsule floats over the page, so it claims its own zone or every click falls through to the page. -->
    <div
      class="notice-capsule float-surface"
      class:open
      role="alert"
      use:reportInteractiveZone={{ id: "notices" }}
    >
      <div class="notice-row">
        <span class="notice-message">{first.message}</span>
        {@render trailing(first)}
        {#if rest.length > 0}
          <button
            class="notice-more"
            type="button"
            aria-expanded={open}
            onclick={() => (expanded = !open)}
            onkeydown={(event) => {
              if (event.key === "Escape" && open) {
                event.stopPropagation();
                expanded = false;
              }
            }}
          >
            {open ? t("notices.more", { count: rest.length }) : t("notices.moreNotices", { count: rest.length })}
            <Icon name="chevronDown" size={10} />
          </button>
        {/if}
        {@render close(first)}
      </div>
      {#if open}
        {#each rest as notice (notice.id)}
          <div class="notice-row">
            <span class="notice-message">{notice.message}</span>
            {@render trailing(notice)}
            {@render close(notice)}
          </div>
        {/each}
      {/if}
    </div>
  {/if}
</div>

<style>
  .banner-host {
    bottom: auto;
    padding: 8px 16px 0;
    display: grid;
    justify-content: center;
    z-index: 10000;
  }

  .notice-capsule {
    display: flex;
    flex-direction: column;
    max-width: 640px;
    border-radius: var(--radius-chip);
    color: var(--text-primary);
    font-size: var(--font-size-md);
    /* The chrome lets clicks through to the page by default; the capsule takes its own. */
    pointer-events: auto;
    animation: float-popover-in var(--motion-duration-overlay) var(--motion-ease-spring) both;
  }

  .notice-capsule.open {
    min-width: min(480px, 100%);
    border-radius: var(--radius-lg);
  }

  .notice-row {
    display: flex;
    align-items: center;
    gap: 12px;
    min-height: 40px;
    padding: 4px 8px 4px 16px;
  }

  .notice-capsule.open .notice-row {
    min-height: 44px;
    padding: 8px 12px 8px 16px;
  }

  .notice-row + .notice-row {
    border-top: 1px solid var(--separator);
  }

  .notice-message {
    flex: 1;
    min-width: 0;
  }

  .notice-more {
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    height: 24px;
    padding: 0 10px;
    border: 0;
    border-radius: var(--radius-chip);
    background: var(--bg-hover);
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .notice-capsule.open .notice-more {
    background: transparent;
    color: var(--text-muted);
  }

  .notice-capsule.open .notice-more :global(.icon) {
    transform: rotate(180deg);
  }

  .notice-more:hover {
    color: var(--text-primary);
  }

  .notice-close {
    flex: none;
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
  }

  .notice-close:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .notice-more:focus-visible,
  .notice-close:focus-visible {
    outline: var(--focus-outline);
  }

  @media (prefers-reduced-motion: reduce) {
    .notice-capsule {
      animation: notice-fade 150ms ease both !important;
    }
  }

  @keyframes notice-fade {
    from {
      opacity: 0;
    }
  }
</style>
