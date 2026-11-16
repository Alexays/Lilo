<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getInterfaceStyle, setSetting } from "../../stores/settings.svelte";

  const choices = ["default", "streamlined"] as const;
  const selected = $derived(getInterfaceStyle());

  function handleKeydown(event: KeyboardEvent): void {
    const step = ["ArrowRight", "ArrowDown"].includes(event.key) ? 1 : ["ArrowLeft", "ArrowUp"].includes(event.key) ? -1 : 0;
    if (!step && event.key !== "Home" && event.key !== "End") return;
    event.preventDefault();
    const index = event.key === "Home" ? 0 : event.key === "End" ? 1 : (choices.indexOf(selected) + step + 2) % 2;
    setSetting("interfaceStyle", choices[index]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[index]?.focus();
  }
</script>

<div class="choices" role="radiogroup" tabindex="-1" aria-label={t("settings.items.interfaceStyle.title")} onkeydown={handleKeydown}>
  {#each choices as choice (choice)}
    <button class="option" class:on={choice === selected} class:streamlined={choice === "streamlined"}
      role="radio" aria-checked={choice === selected}
      tabindex={choice === selected ? 0 : -1} onclick={() => setSetting("interfaceStyle", choice)}>
      <span class="preview" aria-hidden="true">
        <span class="sample-address"></span>
        <span class="sample-favorites"><i></i><i></i><i></i></span>
        {#if choice === "streamlined"}<span class="sample-heading"></span>{/if}
        {#each [0, 1, 2] as row (row)}<span class="sample-row" class:active={row === 1}><i></i><b></b></span>{/each}
      </span>
      <span>{t(`settings.items.interfaceStyle.${choice}`)}</span>
    </button>
  {/each}
</div>

<style>
  .choices { display: grid; grid-template-columns: repeat(auto-fit, minmax(100px, 128px)); gap: 16px; margin-top: 10px; }
  .option { display: flex; flex-direction: column; align-items: center; gap: 6px; border: 0; padding: 0; background: none;
    font: inherit; font-size: var(--font-size-sm); color: var(--text-secondary); cursor: pointer; }
  .option.on { color: var(--text-primary); font-weight: var(--font-weight-medium); }
  .option:focus-visible { outline: none; }
  .preview { display: flex; flex-direction: column; width: 100%; height: 132px; gap: 4px; padding: 10px;
    background: var(--group-box-bg); border: 1px solid var(--border); border-radius: var(--radius-md); box-sizing: border-box; }
  .option.on .preview { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
  .option:focus-visible .preview { outline: var(--focus-outline); outline-offset: 3px; }
  .sample-address { height: 12px; flex: none; border-radius: var(--radius-xs); background: var(--bg-hover); }
  .sample-favorites { display: flex; gap: 4px; height: 16px; flex: none; margin-bottom: 2px; }
  .sample-favorites i { flex: 1; border-radius: var(--radius-xs); background: var(--bg-hover); }
  .sample-heading { width: 35%; height: 4px; background: var(--text-secondary); border-radius: var(--radius-2xs); margin-block: 3px; }
  .sample-row { display: flex; align-items: center; gap: 6px; height: 13px; flex: none; border-radius: var(--radius-xs); padding: 0 4px; }
  .sample-row.active { background: var(--bg-hover); }
  .sample-row i { width: 6px; height: 6px; background: var(--accent); border-radius: var(--radius-2xs); }
  .sample-row b { width: 60%; height: 3px; background: var(--text-secondary); border-radius: var(--radius-2xs); }
  .streamlined .sample-row { height: 17px; }
  .streamlined .sample-row.active { box-shadow: var(--shadow-control); }
</style>
