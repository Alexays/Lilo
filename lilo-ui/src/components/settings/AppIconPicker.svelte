<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { getAppIcons, getSetting, setSetting } from "../../stores/settings.svelte";

  const selected = $derived(getSetting("appIcon", "classic"));

  $effect(() => {
    if (getAppIcons().length === 0) settingsActions.loadAppIcons();
  });
</script>

<div class="picker" role="radiogroup" aria-label={t("settings.items.appIcon.title")}>
  {#each getAppIcons() as icon (icon.id)}
    <button
      class="tile"
      class:on={selected === icon.id}
      role="radio"
      aria-checked={selected === icon.id}
      aria-label={t(`settings.appIcons.${icon.id}`)}
      use:tooltip={t(`settings.appIcons.${icon.id}`)}
      onclick={() => setSetting("appIcon", icon.id)}
    >
      <img src={icon.dataURL} alt="" width="56" height="56" />
    </button>
  {/each}
</div>

<style>
  .picker {
    display: grid;
    grid-template-columns: repeat(auto-fill, 64px);
    gap: 10px;
    margin-top: 10px;
  }

  .tile {
    width: 64px;
    height: 64px;
    padding: 2px;
    border: 2px solid transparent;
    border-radius: var(--radius-lg);
    background: transparent;
    cursor: pointer;
    transition: transform var(--motion-duration-normal) var(--motion-ease-bounce), border-color var(--transition-fast);
  }

  .tile:hover {
    transform: translateY(-2px);
  }

  .tile.on {
    border-color: var(--accent);
  }

  .tile:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  img {
    display: block;
    width: 100%;
    height: 100%;
  }

  @media (prefers-reduced-motion: reduce) {
    .tile {
      transition: none;
    }
  }
</style>
