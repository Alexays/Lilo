<!-- Chip shown while work keeps the Mac awake: a quiet sun that fades in and out, since holding comes
     and goes often; it names the state only on hover, or for a few seconds when the lid mode starts. Its popover lists what holds the Mac, waiting terminals first, and gives sleep back.
     The popover is mounted on the body, so it may run past a narrow sidebar over the page. -->
<script lang="ts">
  import { fade } from "svelte/transition";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { keepAwakeActions, spaceActions, terminalActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { formatTerminalDuration } from "../../lib/terminalTitle";
  import { tooltip } from "../../lib/tooltip";
  import { getAgentsSpaceId } from "../../stores/agents.svelte";
  import { getKeepAwakeState, getTerminals } from "../../stores/keepAwake.svelte";

  const keepAwake = $derived(getKeepAwakeState());
  const holding = $derived(
    getTerminals()
      .filter((terminal) => keepAwake.tabIds.includes(terminal.tabId))
      .sort((a, b) => (b.awaitingInputSince > 0 ? 1 : 0) - (a.awaitingInputSince > 0 ? 1 : 0)),
  );
  // Booleans, not the state object: every keep-awake update sends a new object, and depending on
  // it would close the popover and unfold the label on each one.
  const holds = $derived(keepAwake.keepsAwake);
  const lidClosed = $derived(keepAwake.holdsLidClosed);
  const label = $derived(t(lidClosed ? "sidebar.keepAwakeLid" : "sidebar.keepAwake"));

  // Holding can drop for a moment (a Space switch, a command handing over to the next): the chip
  // stays through such gaps instead of leaving and coming back unfolded.
  let shown = $state(false);
  $effect(() => {
    if (holds) {
      shown = true;
      return;
    }
    const timer = setTimeout(() => (shown = false), 1500);
    return () => clearTimeout(timer);
  });

  // Recomputes, closing the popover, each time the chip appears or goes.
  let open = $derived.by(() => {
    void shown;
    return false;
  });
  // Durations are read when the popover opens, not ticked while it stays up.
  const now = $derived.by(() => {
    void open;
    return Date.now();
  });

  // Only the lid mode, which drains the battery, unfolds the label unasked; it folds again so long
  // Space names get their room back.
  let expanded = $state(false);
  $effect(() => {
    if (!shown || !lidClosed) return;
    expanded = true;
    const timer = setTimeout(() => (expanded = false), 4000);
    return () => clearTimeout(timer);
  });

  const POPOVER_WIDTH = 280;
  const VIEWPORT_MARGIN = 8;
  let pillEl: HTMLButtonElement | undefined = $state();
  let popoverEl: HTMLDivElement | undefined = $state();

  // Read when it opens: right-aligned with the sidebar's gutter, pushed right over the page when
  // the sidebar is narrower than the popover.
  const position = $derived.by(() => {
    if (!open || !pillEl) return { top: 0, left: 0 };
    const rect = pillEl.getBoundingClientRect();
    const left = Math.min(
      Math.max(VIEWPORT_MARGIN, rect.right + 6 - POPOVER_WIDTH),
      window.innerWidth - POPOVER_WIDTH - VIEWPORT_MARGIN,
    );
    return { top: rect.bottom + 6, left };
  });

  $effect(() => {
    popoverEl?.querySelector<HTMLElement>(".float-row, .float-button")?.focus();
  });

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      event.preventDefault();
      open = false;
      pillEl?.focus();
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const rows = Array.from(popoverEl?.querySelectorAll<HTMLElement>(".float-row, .float-button") ?? []);
    if (rows.length === 0) return;
    event.preventDefault();
    const step = event.key === "ArrowDown" ? 1 : -1;
    const index = rows.indexOf(document.activeElement as HTMLElement);
    rows[(index + step + rows.length) % rows.length]?.focus();
  }

  function reveal(tabId: string): void {
    terminalActions.reveal(tabId);
    open = false;
  }

  function showAgents(): void {
    spaceActions.switchTo(getAgentsSpaceId());
    open = false;
  }
</script>

{#snippet sunGlyph()}
  <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" aria-hidden="true">
    <circle cx="6" cy="6" r="2.1" />
    <path d="M6 1v1M6 10v1M1 6h1M10 6h1M2.5 2.5l.7.7M8.8 8.8l.7.7M2.5 9.5l.7-.7M8.8 3.2l.7-.7" />
  </svg>
{/snippet}

{#if shown}
  <button
    class="pill"
    class:expanded
    class:open
    class:lid={lidClosed}
    bind:this={pillEl}
    use:tooltip={{ text: t("sidebar.keepAwakeHint"), placement: "bottom", disabled: open }}
    aria-label={label}
    aria-expanded={open}
    onclick={() => (open = !open)}
    in:fade={{ duration: prefersReducedMotion() ? 0 : 180 }}
    out:fade={{ duration: prefersReducedMotion() ? 0 : 140 }}
  >
    {@render sunGlyph()}
    <span class="text" aria-hidden="true">{label}</span>
  </button>

  {#if open}
    <div
      class="popover float-surface float-popover"
      role="dialog"
      tabindex="-1"
      aria-label={label}
      style="top: {position.top}px; left: {position.left}px; width: {POPOVER_WIDTH}px;"
      bind:this={popoverEl}
      use:portal
      use:reportInteractiveZone={{ id: "keep-awake-popover" }}
      onkeydown={handleKeydown}
      {@attach dismissable({ onDismiss: () => (open = false), ignore: ".pill", returnFocus: pillEl })}
    >
      <div class="float-popover-head">
        <span class="float-popover-title">{label}</span>
        <span class="float-popover-subtitle">{t("sidebar.keepAwakeBecause")}</span>
      </div>

      {#if holding.length || keepAwake.agents.length}
        <ul class="items">
          {#each holding as terminal (terminal.tabId)}
            {@const isWaiting = terminal.awaitingInputSince > 0}
            {@const since = isWaiting ? terminal.awaitingInputSince : terminal.startedAt}
            {@const duration = since ? formatTerminalDuration((now - since) / 1000) : ""}
            <li>
              <button
                class="float-row"
                aria-label={[
                  terminal.title,
                  isWaiting
                    ? t("sidebar.terminalsWaitingFor", { duration })
                    : duration ? t("sidebar.terminalsWorkingFor", { duration }) : t("tabItem.terminalBusy"),
                  terminal.spaceName,
                ].filter(Boolean).join(", ")}
                onclick={() => reveal(terminal.tabId)}
              >
                <span class="dot" class:waiting={isWaiting} aria-hidden="true"></span>
                <span class="name">{terminal.title}</span>
                <span class="meta" class:waiting={isWaiting} aria-hidden="true">
                  {[isWaiting ? t("tabItem.terminalAttention") : terminal.spaceName, duration].filter(Boolean).join(" · ")}
                </span>
              </button>
            </li>
          {/each}
          {#each keepAwake.agents as agent (agent)}
            <li>
              <button class="float-row" onclick={showAgents}>
                <span class="dot agent" aria-hidden="true"></span>
                <span class="name">{agent}</span>
                <span class="meta">{t("sidebar.agentWorking")}</span>
              </button>
            </li>
          {/each}
        </ul>
      {/if}

      <div class="float-foot">
        <span class="foot-hint">{t("sidebar.keepAwakeStopHint")}</span>
        <button class="float-button" onclick={() => { keepAwakeActions.snooze(); open = false; }}>{t("sidebar.keepAwakeStop")}</button>
      </div>
    </div>
  {/if}
{/if}

<style>
  /* Gold mixed with the text colour: light on dark Space colours, dark on light ones. */
  .pill {
    --awake-ink: color-mix(in srgb, var(--keep-awake) 70%, var(--text-primary));
    display: flex;
    align-items: center;
    height: 22px;
    padding: 0 4px;
    border: none;
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--keep-awake) 15%, transparent);
    color: var(--awake-ink);
    font-family: inherit;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    white-space: nowrap;
    cursor: pointer;
    transition:
      padding 240ms var(--motion-ease-spring),
      box-shadow var(--transition-fast);
  }

  .pill:hover,
  .pill.open {
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--keep-awake) 40%, transparent);
  }

  .pill:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  /* Filled in the mode that drains the most, even folded. */
  .pill.lid {
    background: var(--keep-awake);
    color: var(--on-pastel);
  }

  .text {
    max-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    transition:
      max-width 240ms var(--motion-ease-spring),
      margin-left 240ms var(--motion-ease-spring);
  }

  .pill.expanded,
  .pill:hover,
  .pill:focus-visible,
  .pill.open {
    padding: 0 8px 0 6px;
  }

  .pill.expanded .text,
  .pill:hover .text,
  .pill:focus-visible .text,
  .pill.open .text {
    /* Truncated before the Space name it sits beside: a narrow sidebar keeps the name readable. */
    max-width: clamp(0px, calc(var(--sidebar-width, 260px) - 160px), 160px);
    margin-left: 4px;
  }

  @media (prefers-reduced-motion: reduce) {
    .pill,
    .text {
      transition: none;
    }
  }

  .popover {
    position: fixed;
    z-index: var(--z-popover);
    transform-origin: calc(100% - 12px) 0;
  }

  .items {
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: 2px;
    max-height: 240px;
    overflow-y: auto;
  }

  .name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .meta {
    max-width: 55%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-xs);
    color: var(--text-muted);
    font-variant-numeric: tabular-nums;
  }

  .meta.waiting {
    color: var(--keep-awake);
  }

  .dot {
    flex: none;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--accent) 55%, white);
  }

  .dot.waiting {
    background: var(--keep-awake);
  }

  .dot.agent {
    background: var(--agents);
  }

  .foot-hint {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-xs);
    color: var(--text-muted);
  }
</style>
