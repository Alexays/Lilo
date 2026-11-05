<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { getActiveSpace } from "../../stores/spaces.svelte";

  // Where a call goes when its tab is left: docked in the sidebar, or a floating window over the page.
  const OPTIONS = [
    { value: "true", labelKey: "settings.callDock.sidebar" },
    { value: "false", labelKey: "settings.callDock.floating" },
  ];

  const selected = $derived(getSetting("dockCallsInSidebar", "true"));

  function handleKeydown(event: KeyboardEvent): void {
    if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
    event.preventDefault();
    const next = selected === "true" ? "false" : "true";
    setSetting("dockCallsInSidebar", next);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[next === "true" ? 0 : 1]?.focus();
  }
</script>

<div
  class="options"
  style:--space-color={getActiveSpace()?.color}
  role="radiogroup"
  tabindex="-1"
  aria-label={t("settings.items.dockCallsInSidebar.title")}
  onkeydown={handleKeydown}
>
  {#each OPTIONS as option (option.value)}
    <button
      class="option"
      class:on={selected === option.value}
      role="radio"
      aria-checked={selected === option.value}
      tabindex={selected === option.value ? 0 : -1}
      onclick={() => setSetting("dockCallsInSidebar", option.value)}
    >
      <span class="shot" class:docked={option.value === "true"} aria-hidden="true">
        <span class="sidebar"><i></i><i></i><i></i></span>
        <span class="page"><i></i><i></i></span>
        <span class="call"></span>
      </span>
      {t(option.labelKey)}
    </button>
  {/each}
</div>

<style>
  .options {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 168px));
    gap: var(--space-12);
    margin-top: var(--space-10);
  }

  .option {
    display: grid;
    gap: var(--space-6);
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .option.on {
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  .option:focus-visible {
    outline: none;
  }

  .option:focus-visible .shot {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  /* A window: the Space's sidebar, the page, and the call where it goes. */
  .shot {
    position: relative;
    aspect-ratio: 16 / 10;
    overflow: hidden;
    border: 2px solid transparent;
    border-radius: var(--radius-md);
    box-shadow: 0 0 0 1px var(--separator);
    background: color-mix(in srgb, var(--space-color, var(--accent)) 40%, var(--bg-primary));
  }

  .option.on .shot {
    border-color: var(--accent);
  }

  .sidebar,
  .page,
  .call {
    position: absolute;
  }

  .sidebar {
    left: 8%;
    top: 14%;
    width: 22%;
    display: grid;
    gap: 5px;
  }

  .sidebar i,
  .page i {
    height: 4px;
    border-radius: var(--radius-2xs);
    background: color-mix(in srgb, var(--text-primary) 22%, transparent);
  }

  .page {
    left: 34%;
    top: 6%;
    right: 4%;
    bottom: 6%;
    display: grid;
    align-content: start;
    gap: 6px;
    padding: 10%;
    border-radius: var(--radius-xs);
    background: var(--bg-primary);
  }

  .page i:last-child {
    width: 70%;
  }

  /* Always dark: a video frame, whatever the theme. */
  .call {
    border-radius: var(--radius-xs);
    background: var(--terminal-tile-bg);
    box-shadow: var(--shadow-sm);
  }

  .docked .call {
    left: 6%;
    bottom: 8%;
    width: 24%;
    height: 26%;
  }

  .shot:not(.docked) .call {
    right: 6%;
    bottom: 10%;
    width: 30%;
    height: 32%;
  }
</style>
