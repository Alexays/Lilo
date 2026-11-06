<script lang="ts">
  import { announce } from "../../lib/announce";
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
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";

  let query = $state("");
  // The row whose keys button takes focus back once its conflict's Replace or Cancel is gone.
  let refocusId: string | null = null;

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

  // One keycap per modifier, then one for the key itself ("F12", "Space").
  function keycaps(combo: string): string[] {
    const modifiers = combo.match(/^[⌃⌥⇧⌘]*/)?.[0] ?? "";
    const key = combo.slice(modifiers.length);
    return [...modifiers, ...(key ? [key] : [])];
  }
</script>

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

<div class="shortcuts-list">
  {#each groups as group (group.title)}
    <UiInsetList title={group.title}>
      {#each group.items as item (item.id)}
        {@const conflict = getShortcutConflict()?.id === item.id ? getShortcutConflict() : null}
        {@const recording = getRecordingShortcut() === item.id}
        <UiListRow
          title={item.title}
          description={conflict
            ? t("settings.shortcuts.conflict", { keys: conflict.keys, name: conflict.owner })
            : recording ? t("settings.shortcuts.recordingHint") : undefined}
        >
          {#snippet action()}
            {#if conflict}
              <!-- The keys button these replace held focus: Replace takes it, and the conflict is spoken. -->
              <span
                class="conflict-actions"
                {@attach (node) => {
                  node.querySelector("button")?.focus();
                  announce(t("settings.shortcuts.conflict", { keys: conflict.keys, name: conflict.owner }));
                }}
              >
                <UiButton
                  variant="primary"
                  onclick={() => {
                    refocusId = item.id;
                    settingsActions.setShortcut(item.id, conflict.combo);
                  }}
                >
                  {t("settings.shortcuts.replace")}
                </UiButton>
                <UiButton
                  onclick={() => {
                    refocusId = item.id;
                    dismissShortcutConflict();
                  }}
                >{t("settings.shortcuts.cancel")}</UiButton>
              </span>
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
                aria-label={`${item.title}, ${recording
                  ? t("settings.shortcuts.pressKeys")
                  : item.keys.length === 0 ? t("settings.shortcuts.none") : item.keys.join(", ")}`}
                onclick={() => recordShortcut(recording ? null : item.id)}
                {@attach (node) => {
                  if (refocusId !== item.id) return;
                  refocusId = null;
                  node.focus();
                }}
              >
                {#if recording}
                  {t("settings.shortcuts.pressKeys")}
                {:else if item.keys.length === 0}
                  {t("settings.shortcuts.none")}
                {:else}
                  {#each item.keys as keys (keys)}
                    <span class="combo">{#each keycaps(keys) as cap, index (index)}<kbd>{cap}</kbd>{/each}</span>
                  {/each}
                {/if}
              </button>
            {/if}
          {/snippet}
        </UiListRow>
      {/each}
    </UiInsetList>
  {:else}
    <p class="shortcuts-empty">{t("settings.shortcuts.noResults")}</p>
  {/each}
</div>

<style>
  .shortcuts-empty {
    margin: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-md);
  }

  .shortcuts-toolbar {
    display: flex;
    align-items: center;
    gap: var(--space-12);
  }

  .shortcuts-toolbar > :global(:first-child) {
    flex: 1;
  }

  .shortcuts-list {
    display: grid;
    gap: 22px;
  }

  /* Single-line rows: a list row's height, not a detail row's. */
  .shortcuts-list :global(.ui-list-row) {
    padding-block: var(--space-2);
    min-height: 32px;
  }

  .conflict-actions {
    display: contents;
  }

  .shortcut-keys {
    display: flex;
    gap: var(--space-12);
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    cursor: pointer;
  }

  .shortcut-keys:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .combo {
    display: flex;
    gap: var(--space-4);
  }

  kbd,
  .shortcut-keys.recording,
  .shortcut-keys.unbound {
    display: grid;
    place-items: center;
    min-width: 20px;
    height: 20px;
    padding: 0 var(--space-6);
    border-radius: var(--radius-sm);
    background: var(--bg-elevated);
    box-shadow: inset 0 0 0 1px var(--border), 0 1px 0 var(--border);
    font-family: inherit;
    font-size: var(--font-size-xs);
    white-space: nowrap;
  }

  .shortcut-keys.unbound {
    color: var(--text-muted);
  }

  .shortcut-keys.recording {
    color: var(--accent-ink);
    box-shadow: inset 0 0 0 1.5px var(--accent);
  }

  .shortcut-keys:hover kbd,
  .shortcut-keys.unbound:hover {
    background: var(--bg-hover);
  }
</style>
