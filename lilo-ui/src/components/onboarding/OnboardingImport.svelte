<script lang="ts">
  import { untrack } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { announce } from "../../lib/announce";
  import { importActions } from "../../lib/bridge/actions";
  import type { ImportKind, ImportSourceInfo } from "../../lib/bridge/protocol";
  import { profileKey, toggleSource } from "./onboardingModel";
  import { getImportState, goNext, runSelectedImport, setImportChoices } from "../../stores/onboarding.svelte";

  const KINDS: ImportKind[] = ["bookmarks", "tabs", "history", "cookies", "extensions"];
  const importState = getImportState();
  const choices = $derived(importState.choices);
  const sources = $derived(importState.sources ?? []);
  const finished = $derived(importState.summary !== null);
  const imported = $derived((importState.summary ?? []).reduce((sum, item) => sum + item.imported, 0));
  const chosenSources = $derived(sources.filter((source) => source.profiles.some((profile) => choices.profiles.includes(profileKey(source.id, profile.id)))));
  const chosenExtensions = $derived(
    chosenSources.flatMap((source) => source.profiles
      .filter((profile) => choices.profiles.includes(profileKey(source.id, profile.id)))
      .flatMap((profile) => profile.extensions)),
  );
  const failures = $derived(
    (importState.summary ?? []).filter((item) => item.error)
      .map((item) => `${sources.find((source) => source.id === item.sourceId)?.name ?? item.sourceId} (${t(`onboarding.import.kind.${item.kind}`)})`),
  );
  // Only Chromium cookies go through the Keychain prompt worth announcing.
  const keychainPrompt = $derived(importState.running && choices.kinds.includes("cookies") && chosenSources.some((source) => source.family === "chromium"));
  let advanced = $state(false);

  // The import runs for a while with no focus change: its outcome is spoken once, as it lands.
  let outcomeSpoken = untrack(() => finished);
  $effect(() => {
    if (!finished || outcomeSpoken) return;
    outcomeSpoken = true;
    announce([
      t("onboarding.import.done", { count: imported }),
      failures.length > 0 ? t("onboarding.import.partial", { list: failures.join(", ") }) : "",
    ].filter(Boolean).join(" "));
  });

  function toggle<T>(list: T[], value: T): T[] {
    return list.includes(value) ? list.filter((item) => item !== value) : [...list, value];
  }

  function progressOf(sourceId: string): number | null {
    const entries = Object.entries(importState.progress).filter(([key]) => key.startsWith(`${sourceId}/`));
    if (entries.length === 0) return null;
    const done = entries.reduce((sum, [, value]) => sum + value.done, 0);
    const total = entries.reduce((sum, [, value]) => sum + value.total, 0);
    return total ? done / total : 1;
  }
</script>

{#snippet logo(source: ImportSourceInfo)}
  {#if source.iconDataURL}
    <img class="logo" src={source.iconDataURL} alt="" width="32" height="32" />
  {:else}
    <span class="ico" data-family={source.family}>{source.name[0]}</span>
  {/if}
{/snippet}

<h3>{t("onboarding.import.title")}</h3>
<p class="ob-sub">{t("onboarding.import.subtitle")}</p>

{#if importState.sources === null}
  <p class="ob-sub">{t("onboarding.import.scanning")}</p>
{:else if sources.length === 0}
  <p class="ob-sub">{t("onboarding.import.none")}</p>
{:else}
  <div class="cards" role="group" aria-label={t("onboarding.import.title")}>
    {#each sources as source (source.id)}
      {@const on = chosenSources.includes(source)}
      {@const progress = progressOf(source.id)}
      {#if source.needsFullDiskAccess}
        <button class="src locked" onclick={() => importActions.openFullDiskAccessSettings()}>
          {@render logo(source)}
          <span class="name">{source.name}<small class="hint">{t("onboarding.import.allow")}</small></span>
        </button>
      {:else}
        <button class="src" class:on aria-pressed={on} disabled={importState.running || finished}
          onclick={() => setImportChoices(toggleSource(source, choices))}>
          {@render logo(source)}
          <span class="name">{source.name}</span>
          <span class="check" aria-hidden="true">{#if on}<svg width="14" height="14" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.5 6.2l2.3 2.3 4.7-5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" /></svg>{/if}</span>
          {#if progress !== null}<span class="bar"><i style:width="{progress * 100}%"></i></span>{/if}
        </button>
      {/if}
    {/each}
  </div>

  {#if keychainPrompt}
    <p class="note">{t("onboarding.import.keychainNote")}</p>
  {:else if finished}
    <p class="note done">{t("onboarding.import.done", { count: imported })}</p>
    {#if failures.length > 0}<p class="note">{t("onboarding.import.partial", { list: failures.join(", ") })}</p>{/if}
  {:else}
    <button class="more" aria-expanded={advanced} onclick={() => (advanced = !advanced)}>
      {advanced ? t("onboarding.import.lessOptions") : t("onboarding.import.moreOptions")}
    </button>
  {/if}

  {#if advanced && !importState.running && !finished}
    <div class="advanced">
      {#each chosenSources as source (source.id)}
        {#if source.profiles.length > 1}
          <p class="lab">{t("onboarding.import.profiles", { browser: source.name })}</p>
          {#each source.profiles as profile (profile.id)}
            {@const key = profileKey(source.id, profile.id)}
            <label><input type="checkbox" checked={choices.profiles.includes(key)}
              onchange={() => setImportChoices({ ...choices, profiles: toggle(choices.profiles, key) })} /> {profile.name}</label>
          {/each}
        {/if}
      {/each}
      <p class="lab">{t("onboarding.import.kinds")}</p>
      <div class="chips">
        {#each KINDS as kind (kind)}
          <button class="chip" class:off={!choices.kinds.includes(kind)} aria-pressed={choices.kinds.includes(kind)}
            onclick={() => setImportChoices({ ...choices, kinds: toggle(choices.kinds, kind) })}>{t(`onboarding.import.kind.${kind}`)}</button>
        {/each}
      </div>
      {#if choices.kinds.includes("extensions") && chosenExtensions.length > 0}
        <p class="lab">{t("onboarding.import.extensions")}</p>
        {#each chosenExtensions as ext (ext.id)}
          <label><input type="checkbox" checked={choices.extensionIds.includes(ext.id)}
            onchange={() => setImportChoices({ ...choices, extensionIds: toggle(choices.extensionIds, ext.id) })} /> {ext.name}</label>
        {/each}
      {/if}
    </div>
  {/if}
{/if}

<div class="ob-foot">
  {#if finished}<span></span>{:else}<button class="ob-btn ghost" disabled={importState.running} onclick={goNext}>{t("onboarding.skip")}</button>{/if}
  {#if finished || sources.length === 0}
    <button class="ob-btn primary" onclick={goNext}>{t("onboarding.continue")}</button>
  {:else}
    <button class="ob-btn primary" disabled={importState.running || chosenSources.length === 0} onclick={runSelectedImport}>
      {importState.running ? t("onboarding.import.running") : t("onboarding.import.run")}
    </button>
  {/if}
</div>

<style>
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 8px; }
  .src { position: relative; display: flex; align-items: center; gap: 10px; padding: 12px; border-radius: var(--radius-lg); border: 2px solid transparent;
    background: var(--bg-hover); color: var(--text-primary); font-size: var(--font-size-lg); font-weight: var(--font-weight-semibold); cursor: pointer; text-align: left; overflow: hidden;
    transition: border-color var(--motion-duration-normal), transform .2s var(--motion-ease-spring); }
  .src:hover:not(:disabled) { transform: translateY(-1px); }
  .src.on { border-color: var(--accent); }
  .src:disabled { cursor: default; }
  .src.locked .logo, .src.locked .ico { opacity: .75; }
  .ico { width: 30px; height: 30px; border-radius: var(--radius-sm); display: grid; place-items: center; color: #fff; font-weight: var(--font-weight-bold); background: #6d5ae6; flex: none; }
  .ico[data-family="safari"] { background: #2f9cf0; } .ico[data-family="firefox"] { background: #ff7139; }
  .name { flex: 1; }
  .check { color: var(--accent); font-size: var(--font-size-lg); }
  .logo { width: 32px; height: 32px; flex: none; }
  .hint { display: block; margin-top: 2px; font-size: var(--font-size-xs); font-weight: var(--font-weight-medium); color: var(--accent-ink); }
  .bar { position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: var(--bg-active); }
  .bar i { display: block; height: 100%; background: var(--accent); transition: width .6s var(--motion-ease-standard); }
  .note { font-size: var(--font-size-sm); color: var(--text-secondary); margin: 12px 0 0; }
  .note.done { color: var(--success-text); font-weight: var(--font-weight-semibold); }
  .more { border: 0; background: none; padding: 0; margin-top: 12px; font-size: var(--font-size-sm); color: var(--accent-ink); cursor: pointer; }
  .advanced { margin-top: 10px; padding: 12px; border-radius: var(--radius-lg); background: var(--bg-hover); font-size: var(--font-size-sm); color: var(--text-primary); }
  .advanced label { display: block; padding: 4px 0; }
  .lab { margin: 8px 0 6px; font-size: var(--font-size-xs); font-weight: var(--font-weight-semibold); color: var(--text-secondary); }
  .lab:first-child { margin-top: 0; }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; }
  .chip { font-size: var(--font-size-sm); padding: 4px 10px; border-radius: var(--radius-chip); border: 0; cursor: pointer; background: var(--accent-tint-14); color: var(--accent-ink); }
  .chip.off { background: var(--bg-active); color: var(--text-muted); text-decoration: line-through; }
  @media (prefers-reduced-motion: reduce) { .src, .bar i { transition: none; } }
</style>
