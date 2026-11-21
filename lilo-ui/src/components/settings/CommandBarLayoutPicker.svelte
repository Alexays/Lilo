<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { getActiveSpace } from "../../stores/spaces.svelte";

  const OPTIONS = [
    { value: "default", labelKey: "settings.commandBarLayout.default" },
    { value: "compact", labelKey: "settings.commandBarLayout.compact" },
  ];

  const selected = $derived(getSetting("commandBarLayout", "default"));

  function handleKeydown(event: KeyboardEvent): void {
    if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
    event.preventDefault();
    const next = selected === "default" ? "compact" : "default";
    setSetting("commandBarLayout", next);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[next === "default" ? 0 : 1]?.focus();
  }
</script>

<div
  class="options"
  style:--space-color={getActiveSpace()?.color}
  role="radiogroup"
  tabindex="-1"
  aria-label={t("settings.items.commandBarLayout.title")}
  onkeydown={handleKeydown}
>
  {#each OPTIONS as option (option.value)}
    <button
      class="option"
      class:on={selected === option.value}
      role="radio"
      aria-checked={selected === option.value}
      tabindex={selected === option.value ? 0 : -1}
      onclick={() => setSetting("commandBarLayout", option.value)}
    >
      <span class="shot" class:compact={option.value === "compact"} aria-hidden="true">
        <span class="preview-bar"><i></i><i></i><i></i></span>
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

  .shot {
    display: grid;
    place-items: center;
    height: 84px;
    border: 2px solid transparent;
    border-radius: var(--radius-md);
    box-shadow: 0 0 0 1px var(--separator);
    background: var(--bg-hover);
  }
  .option.on .shot { border-color: var(--accent); }
  .preview-bar {
    display: grid;
    gap: 6px;
    width: 80%;
    padding: 8px;
    border-radius: var(--radius-sm);
    background: var(--bg-primary);
  }
  .preview-bar i { height: 4px; background: var(--text-muted); border-radius: var(--radius-2xs); }
  .compact .preview-bar { width: 60%; }
  .compact .preview-bar i:last-child { display: none; }
</style>
