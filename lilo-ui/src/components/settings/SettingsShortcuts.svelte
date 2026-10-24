<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    dismissShortcutConflict,
    getRecordingShortcut,
    getShortcutConflict,
    getControlTabOrder,
    getShortcuts,
    recordShortcut,
  } from "../../stores/settings.svelte";
  import SettingsGroupIcon from "./SettingsGroupIcon.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";

  let query = $state("");

  // Read each time the page opens, so shortcuts reassigned in System Settings show; leaving stops a recording.
  $effect(() => {
    settingsActions.loadShortcuts();
    return () => {
      if (getRecordingShortcut()) recordShortcut(null);
    };
  });

  const groups = $derived.by(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return getShortcuts();
    return getShortcuts()
      .map((group) => ({
        ...group,
        items: group.items.filter(
          (item) =>
            item.title.toLowerCase().includes(needle) ||
            item.keys.some((keys) => keys.toLowerCase().includes(needle)),
        ),
      }))
      .filter((group) => group.items.length > 0);
  });
  const hasCustom = $derived(getShortcuts().some((group) => group.items.some((item) => item.custom)));
</script>

<p class="shortcuts-intro">{t("settings.shortcuts.intro")}</p>

<UiInsetList>
  <UiListRow title={t("settings.shortcuts.preset")} description={t("settings.shortcuts.presetDescription")}>
    {#snippet action()}
      <UiButton onclick={() => settingsActions.applyShortcutPreset("lilo")}>{t("settings.shortcuts.presetLilo")}</UiButton>
      <UiButton onclick={() => settingsActions.applyShortcutPreset("arc")}>{t("settings.shortcuts.presetArc")}</UiButton>
    {/snippet}
  </UiListRow>
  <UiListRow title={t("settings.shortcuts.controlTabOrder")} description={t("settings.shortcuts.controlTabOrderDescription")}>
    {#snippet action()}
      <UiSegmented
        value={getControlTabOrder()}
        options={[
          { value: "recent", label: t("settings.shortcuts.controlTabRecent") },
          { value: "sidebar", label: t("settings.shortcuts.controlTabSidebar") },
        ]}
        ariaLabel={t("settings.shortcuts.controlTabOrder")}
        onchange={(value) => settingsActions.setControlTabOrder(value === "sidebar" ? "sidebar" : "recent")}
      />
    {/snippet}
  </UiListRow>
</UiInsetList>

<div class="shortcuts-toolbar">
  <UiSearchField
    value={query}
    placeholder={t("settings.shortcuts.searchPlaceholder")}
    ariaLabel={t("settings.shortcuts.searchPlaceholder")}
    onchange={(value) => (query = value)}
  />
  <UiButton disabled={!hasCustom} onclick={() => settingsActions.applyShortcutPreset("lilo")}>
    {t("settings.shortcuts.resetAll")}
  </UiButton>
</div>

{#each groups as group (group.title)}
  <UiInsetList title={group.title}>
    {#snippet icon()}<SettingsGroupIcon group="settings.shortcuts" />{/snippet}
    {#each group.items as item (item.id)}
      {@const conflict = getShortcutConflict()?.id === item.id ? getShortcutConflict() : null}
      {@const recording = getRecordingShortcut() === item.id}
      <UiListRow
        title={item.title}
        description={conflict ? t("settings.shortcuts.conflict", { keys: conflict.keys, name: conflict.owner }) : undefined}
      >
        {#snippet action()}
          {#if conflict}
            <UiButton variant="primary" onclick={() => settingsActions.setShortcut(item.id, conflict.combo)}>
              {t("settings.shortcuts.replace")}
            </UiButton>
            <UiButton onclick={dismissShortcutConflict}>{t("settings.shortcuts.cancel")}</UiButton>
          {:else}
            {#if item.custom}
              <UiButton variant="ghost" onclick={() => settingsActions.resetShortcut(item.id)}>
                {t("settings.shortcuts.reset")}
              </UiButton>
            {/if}
            <button
              class="shortcut-keys"
              class:recording
              class:unbound={item.keys.length === 0}
              type="button"
              onclick={() => recordShortcut(recording ? null : item.id)}
            >
              {#if recording}
                {t("settings.shortcuts.pressKeys")}
              {:else if item.keys.length === 0}
                {t("settings.shortcuts.none")}
              {:else}
                {#each item.keys as keys (keys)}<kbd>{keys}</kbd>{/each}
              {/if}
            </button>
          {/if}
        {/snippet}
      </UiListRow>
    {/each}
  </UiInsetList>
{:else}
  <p class="shortcuts-intro">{t("settings.shortcuts.noResults")}</p>
{/each}

<style>
  .shortcuts-intro {
    margin: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.45;
  }

  .shortcuts-toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .shortcut-keys {
    display: flex;
    gap: 4px;
    min-height: 24px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .shortcut-keys kbd,
  .shortcut-keys.recording,
  .shortcut-keys.unbound {
    padding: 2px 8px;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    font-family: inherit;
    font-size: var(--font-size-sm);
    letter-spacing: 0.08em;
    white-space: nowrap;
  }

  .shortcut-keys.unbound {
    color: var(--text-muted);
    letter-spacing: normal;
  }

  .shortcut-keys.recording {
    outline: 1.5px solid var(--accent);
    letter-spacing: normal;
  }

  .shortcut-keys:hover kbd,
  .shortcut-keys.unbound:hover {
    background: var(--bg-active);
  }
</style>
