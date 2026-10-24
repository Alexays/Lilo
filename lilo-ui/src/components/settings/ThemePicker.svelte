<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";

  const THEMES = [
    { id: "system", labelKey: "settings.themeSystem" },
    { id: "light", labelKey: "settings.themeLight" },
    { id: "dark", labelKey: "settings.themeDark" },
  ];

  const selected = $derived(getSetting("theme", "system"));
</script>

<div class="themes" role="radiogroup" aria-label={t("settings.items.theme.title")}>
  {#each THEMES as theme (theme.id)}
    <button
      class="theme"
      class:on={selected === theme.id}
      role="radio"
      aria-checked={selected === theme.id}
      onclick={() => setSetting("theme", theme.id)}
    >
      <span class="shot {theme.id}" aria-hidden="true">
        <span class="sidebar"></span>
        <span class="page"><i></i><i></i><i></i></span>
      </span>
      {t(theme.labelKey)}
    </button>
  {/each}
</div>

<style>
  .themes {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 120px));
    gap: 12px;
    margin-top: 10px;
  }

  .theme {
    display: grid;
    gap: 6px;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .theme.on {
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
  }

  .shot {
    display: grid;
    grid-template-columns: 30% 1fr;
    aspect-ratio: 16 / 10;
    overflow: hidden;
    border: 2px solid transparent;
    border-radius: var(--radius-md);
    box-shadow: 0 0 0 1px var(--separator);
    /* Fixed colors: each thumbnail shows its theme, whatever the current one. */
    --light-sidebar: #e2daf1;
    --light-page: #ffffff;
    --light-line: #dcd8e6;
    --dark-sidebar: #1a1a2e;
    --dark-page: #0f0f1a;
    --dark-line: #2c2a40;
  }

  .theme.on .shot {
    border-color: var(--accent);
  }

  .theme:focus-visible {
    outline: none;
  }

  .theme:focus-visible .shot {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .page {
    display: grid;
    align-content: start;
    gap: 4px;
    padding: 8px;
  }

  .page i {
    height: 4px;
    border-radius: var(--radius-2xs);
  }

  .page i:nth-child(2) {
    width: 70%;
  }

  .page i:nth-child(3) {
    width: 50%;
  }

  .light .sidebar { background: var(--light-sidebar); }
  .light .page { background: var(--light-page); }
  .light .page i { background: var(--light-line); }
  .dark .sidebar { background: var(--dark-sidebar); }
  .dark .page { background: var(--dark-page); }
  .dark .page i { background: var(--dark-line); }
  /* System: the page splits into its light and dark halves. */
  .system .sidebar { background: var(--light-sidebar); }
  .system .page { background: linear-gradient(90deg, var(--light-page) 50%, var(--dark-page) 50%); }
  .system .page i { background: linear-gradient(90deg, var(--light-line) 50%, var(--dark-line) 50%); }
</style>
