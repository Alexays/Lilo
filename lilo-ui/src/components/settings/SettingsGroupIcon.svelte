<script lang="ts">
  import SettingsIcon from "./SettingsIcon.svelte";
  import { SETTINGS_GROUP_ICONS, type SettingsGroupKey } from "./settingsPanelModel";

  let { group }: { group: SettingsGroupKey } = $props();

  const icon = $derived(SETTINGS_GROUP_ICONS[group]);
</script>

<span class="settings-group-icon" style:background="var(--tile-{icon.tint})">
  <SettingsIcon name={icon.glyph} />
</span>

<style>
  /* macOS System Settings' colored tile, at heading size. */
  .settings-group-icon {
    display: grid;
    place-items: center;
    flex: none;
    width: 18px;
    height: 18px;
    border-radius: 26%;
    color: var(--on-color);
  }

  .settings-group-icon :global(.settings-icon-svg) {
    width: 12px;
    height: 12px;
  }
</style>
