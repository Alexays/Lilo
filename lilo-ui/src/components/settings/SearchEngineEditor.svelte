<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import {
    BUILTIN_SEARCH_ENGINES,
    moveSearchEngine,
    parseSearchEngines,
    type SearchEngine,
  } from "../../lib/searchEngineModel";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import UiBadge from "../ui/UiBadge.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiTextField from "../ui/UiTextField.svelte";

  const enginesJson = $derived(getSetting("searchEngines", "") || undefined);
  const defaultId = $derived(getSetting("searchEngine", "google"));

  const seed = BUILTIN_SEARCH_ENGINES.map((engine) => ({ ...engine }));
  let engines = $state<SearchEngine[]>(seed);
  let lastSerialized = JSON.stringify(seed);
  let confirmRemoveId = $state<string | null>(null);

  // Drafts stay in the editor until they have a name and a template with the query slot.
  const validEngines = $derived(
    engines.filter((engine) => engine.name.trim() && engine.urlTemplate.includes("%s")),
  );

  // Re-seed only when the incoming JSON differs from the last write, so the editor's own edits
  // (same round-trip JSON) don't reset fields mid-typing.
  $effect(() => {
    if (enginesJson !== undefined && enginesJson !== lastSerialized) {
      engines = parseSearchEngines(enginesJson);
      lastSerialized = JSON.stringify(engines);
    }
  });

  function persist() {
    lastSerialized = JSON.stringify(validEngines);
    setSetting("searchEngines", lastSerialized);
  }

  function edit(id: string, patch: Partial<SearchEngine>) {
    engines = engines.map((engine) => (engine.id === id ? { ...engine, ...patch } : engine));
    persist();
  }

  function move(index: number, direction: -1 | 1) {
    engines = moveSearchEngine(engines, index, direction);
    persist();
  }

  function remove(id: string) {
    confirmRemoveId = null;
    if (engines.length <= 1) return;
    engines = engines.filter((engine) => engine.id !== id);
    if (defaultId === id && validEngines[0]) setSetting("searchEngine", validEngines[0].id);
    persist();
  }

  function add() {
    const id = `engine-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
    engines = [...engines, { id, name: "", urlTemplate: "https://", keyword: "" }];
  }
</script>

<div class="engine-editor">
  {#each engines as engine, index (engine.id)}
    <div class="engine-row">
      <div class="engine-fields">
        <UiTextField
          value={engine.name}
          ariaLabel={t("settings.engineName")}
          placeholder={t("settings.engineName")}
          onchange={(value) => edit(engine.id, { name: value })}
        />
        <UiTextField
          value={engine.urlTemplate}
          type="url"
          ariaLabel={t("settings.engineUrlTemplate")}
          placeholder="https://example.com/search?q=%s"
          onchange={(value) => edit(engine.id, { urlTemplate: value })}
        />
        <UiTextField
          value={engine.keyword}
          ariaLabel={t("settings.engineKeyword")}
          placeholder={t("settings.engineKeyword")}
          onchange={(value) => edit(engine.id, { keyword: value })}
        />
        {#if !engine.name.trim()}
          <p class="engine-error" role="alert">{t("settings.engineNameRequired")}</p>
        {:else if !engine.urlTemplate.includes("%s")}
          <p class="engine-error" role="alert">{t("settings.engineTemplateInvalid")}</p>
        {/if}
      </div>
      <div class="engine-actions">
        {#if confirmRemoveId === engine.id}
          <span class="engine-remove-prompt">{t("settings.engineRemoveConfirm")}</span>
          <UiButton variant="danger" onclick={() => remove(engine.id)}>{t("common.remove")}</UiButton>
          <UiButton onclick={() => (confirmRemoveId = null)}>{t("common.cancel")}</UiButton>
        {:else}
          <!-- Both stay laid out, one hidden, so the slot is as wide on every row and the columns line up. -->
          <span class="engine-default">
            <span class:hidden={engine.id !== defaultId}><UiBadge tone="accent">{t("settings.engineDefault")}</UiBadge></span>
            <span class:hidden={engine.id === defaultId}>
              <UiButton
                disabled={!validEngines.includes(engine)}
                onclick={() => setSetting("searchEngine", engine.id)}>{t("settings.engineSetDefault")}</UiButton>
            </span>
          </span>
          <UiButton variant="ghost" disabled={index === 0} onclick={() => move(index, -1)}>
            <svg viewBox="0 0 12 12" role="img" aria-label={t("settings.engineMoveUp")}><path d="m3 7.5 3-3 3 3" /></svg>
          </UiButton>
          <UiButton variant="ghost" disabled={index === engines.length - 1} onclick={() => move(index, 1)}>
            <svg viewBox="0 0 12 12" role="img" aria-label={t("settings.engineMoveDown")}><path d="m3 4.5 3 3 3-3" /></svg>
          </UiButton>
          <UiButton variant="ghost" disabled={engines.length <= 1} onclick={() => (confirmRemoveId = engine.id)}>
            <svg viewBox="0 0 12 12" role="img" aria-label={t("settings.engineRemove")}><path d="m3.5 3.5 5 5M8.5 3.5l-5 5" /></svg>
          </UiButton>
        {/if}
      </div>
    </div>
  {/each}
  <div class="engine-add">
    <UiButton onclick={add}>{t("settings.engineAdd")}</UiButton>
  </div>
</div>

<style>
  .engine-editor {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  /* The actions drop under the fields rather than squeezing them on a narrow window. */
  .engine-row {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-start;
    gap: 8px;
    padding: 8px;
    border: 1px solid var(--border);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--bg-primary) 96%, transparent);
  }
  .engine-fields {
    display: flex;
    flex-direction: column;
    gap: 6px;
    flex: 1 1 200px;
    min-width: 0;
  }
  .engine-actions {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 2px;
    flex-wrap: wrap;
    justify-content: flex-end;
  }
  .engine-default {
    display: grid;
    margin-right: 6px;
  }
  .engine-default > * {
    grid-area: 1 / 1;
    display: flex;
    justify-content: flex-end;
  }
  .engine-default .hidden {
    visibility: hidden;
  }
  .engine-actions svg {
    width: 12px;
    height: 12px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.5;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  .engine-error {
    margin: 0;
    font-size: var(--font-size-xs);
    color: var(--danger-text);
  }
  .engine-remove-prompt {
    font-size: var(--font-size-sm);
    color: var(--text-secondary);
  }
  .engine-add {
    display: flex;
  }
</style>
