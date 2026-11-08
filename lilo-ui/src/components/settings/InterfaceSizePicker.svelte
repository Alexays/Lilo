<script lang="ts">
  import { INTERFACE_SIZES } from "../../lib/interfaceSizing";
  import { t } from "../../lib/i18n/state.svelte";
  import { getInterfaceSize, setSetting } from "../../stores/settings.svelte";

  const selected = $derived(getInterfaceSize());

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (!step && event.key !== "Home" && event.key !== "End") return;
    event.preventDefault();
    const index = event.key === "Home" ? 0 : event.key === "End" ? INTERFACE_SIZES.length - 1
      : (INTERFACE_SIZES.indexOf(selected) + step + INTERFACE_SIZES.length) % INTERFACE_SIZES.length;
    setSetting("interfaceSize", INTERFACE_SIZES[index]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[index]?.focus();
  }
</script>

<div class="sizes" role="radiogroup" tabindex="-1" aria-label={t("settings.items.interfaceSize.title")} onkeydown={handleKeydown}>
  {#each INTERFACE_SIZES as size, index (size)}
    <button class="option" class:on={selected === size} role="radio" aria-checked={selected === size}
      tabindex={selected === size ? 0 : -1} onclick={() => setSetting("interfaceSize", size)}>
      <span class="shot" style={`--sample-step:${index - 1}`} aria-hidden="true">
        {#each [0, 1, 2] as row (row)}
          <span class="sample-row"><i></i><span class="sample-title" class:short={row === 2}></span></span>
        {/each}
      </span>
      <span>{t(`settings.items.interfaceSize.${size}`)}</span>
      {#if size === "comfortable"}<span class="default-label">{t("settings.items.interfaceSize.default")}</span>{/if}
    </button>
  {/each}
</div>

<style>
  .sizes { display: grid; grid-template-columns: repeat(auto-fit, minmax(90px, 120px)); gap: 12px; margin-top: 10px; }
  .option { display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 0; border: 0; background: transparent;
    color: var(--text-secondary); font: inherit; font-size: var(--font-size-sm); cursor: pointer; }
  .option.on { color: var(--text-primary); font-weight: var(--font-weight-medium); }
  .option:focus-visible { outline: none; }
  .shot { display: flex; flex-direction: column; justify-content: center; gap: 2px; width: 100%; height: 76px; padding: 8px;
    box-sizing: border-box; border: 1px solid var(--border); border-radius: var(--radius-md); background: var(--group-box-bg); }
  .option.on .shot { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
  .option:focus-visible .shot { outline: var(--focus-outline); outline-offset: 3px; }
  .sample-row { display: flex; align-items: center; gap: 6px; height: calc(14px + var(--sample-step) * 3px); padding: 0 4px;
    border-radius: var(--radius-xs); background: var(--bg-hover); }
  .sample-row i { width: calc(6px + var(--sample-step) * 1px); height: calc(6px + var(--sample-step) * 1px); flex: none;
    border-radius: var(--radius-2xs); background: var(--accent); }
  .sample-title { width: 65%; height: calc(2px + var(--sample-step) * 0.5px); border-radius: var(--radius-2xs); background: var(--text-secondary); }
  .sample-title.short { width: 42%; }
  .default-label { color: var(--text-secondary); font-size: var(--font-size-xs); font-weight: var(--font-weight-regular); }
</style>
