<script lang="ts">
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";

  // The default page zoom, drawn as a page at that scale, or the minimum font size, drawn as text at that size.
  let { kind }: { kind: "zoom" | "font" } = $props();

  const ZOOM_LEVELS = ["0.75", "0.9", "1.0", "1.1", "1.25", "1.5"];
  const MINIMUM_FONT_SIZES = ["0", "9", "12", "14", "16", "18", "24"];

  const key = $derived(kind === "zoom" ? "defaultZoom" : "minimumFontSize");
  const options = $derived(kind === "zoom" ? ZOOM_LEVELS : MINIMUM_FONT_SIZES);
  const selected = $derived(getSetting(key, kind === "zoom" ? "1.0" : "0"));
  const percentFormat = $derived(new Intl.NumberFormat(getFormatLocale(), { style: "percent" }));

  function label(option: string): string {
    if (kind === "zoom") return percentFormat.format(Number(option));
    return option === "0" ? t("settings.items.minimumFontSize.none") : t("settings.items.minimumFontSize.points", { size: option });
  }

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = (options.indexOf(selected) + step + options.length) % options.length;
    setSetting(key, options[index]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[index]?.focus();
  }
</script>

<div
  class="options"
  role="radiogroup"
  tabindex="-1"
  aria-label={t(kind === "zoom" ? "settings.items.defaultZoom.title" : "settings.items.minimumFontSize.title")}
  onkeydown={handleKeydown}
>
  {#each options as option (option)}
    <button
      class="option"
      class:on={selected === option}
      role="radio"
      aria-checked={selected === option}
      tabindex={selected === option ? 0 : -1}
      onclick={() => setSetting(key, option)}
    >
      {#if kind === "zoom"}
        <span class="shot page" style:--zoom={option} aria-hidden="true"><i></i><i></i><i></i><i></i></span>
      {:else}
        <!-- The sample renders at the size it stands for: outside the type scale on purpose. -->
        <span class="shot sample" class:none={option === "0"} style:font-size={option === "0" ? undefined : `${option}px`} aria-hidden="true">
          {option === "0" ? "" : "Aa"}
        </span>
      {/if}
      {label(option)}
    </button>
  {/each}
</div>

<style>
  .options {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-8);
    margin-top: var(--space-10);
  }

  .option {
    display: grid;
    justify-items: center;
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
    width: 56px;
    height: 46px;
    overflow: hidden;
    border-radius: var(--radius-md);
    background: var(--bg-elevated);
    box-shadow: 0 0 0 1px var(--separator);
  }

  .option.on .shot {
    box-shadow: 0 0 0 2px var(--accent);
  }

  /* A page's first lines at the zoom level: they grow, and fewer fit across. */
  .page {
    align-content: start;
    gap: calc(3px * var(--zoom));
    padding: 7px;
  }

  .page i {
    height: calc(3px * var(--zoom));
    border-radius: var(--radius-2xs);
    background: var(--text-primary-tint-12);
  }

  .page i:first-child {
    width: calc(40% * var(--zoom));
    background: color-mix(in srgb, var(--text-primary) 24%, transparent);
  }

  .page i:nth-child(2) {
    width: calc(100% * var(--zoom));
  }

  .page i:nth-child(3) {
    width: calc(80% * var(--zoom));
  }

  .page i:nth-child(4) {
    width: calc(60% * var(--zoom));
  }

  .sample {
    place-items: center;
    width: 46px;
    color: var(--text-primary);
    font-weight: var(--font-weight-regular);
    line-height: 1;
  }

  /* No minimum: an empty swatch, struck through. */
  .sample.none {
    background: linear-gradient(
        to top right,
        transparent calc(50% - 0.75px),
        var(--text-muted) calc(50% - 0.75px),
        var(--text-muted) calc(50% + 0.75px),
        transparent calc(50% + 0.75px)
      )
      center / 40% 40% no-repeat,
      var(--bg-elevated);
  }
</style>
