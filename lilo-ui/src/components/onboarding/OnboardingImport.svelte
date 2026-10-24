<script lang="ts">
  import { untrack } from "svelte";
  import { fade, slide } from "svelte/transition";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { announce } from "../../lib/announce";
  import { importActions } from "../../lib/bridge/actions";
  import type { ImportSourceInfo } from "../../lib/bridge/protocol";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { IMPORT_KINDS, importStatus, profileKey, toggleSource } from "./onboardingModel";
  import { getImportState, getOnboarding, goBack, goNext, importedSummary, runSelectedImport, setImportChoices } from "../../stores/onboarding.svelte";

  const onboarding = getOnboarding();
  const importState = getImportState();
  const choices = $derived(importState.choices);
  const sources = $derived(importState.sources ?? []);
  const locked = $derived(sources.filter((source) => source.needsFullDiskAccess));
  const finished = $derived(importState.summary !== null);
  const list = (items: string[]) => new Intl.ListFormat(getLocale(), { type: "conjunction" }).format(items);
  const importedList = $derived(importedSummary(IMPORT_KINDS));
  const doneText = $derived(importedList ? t("onboarding.import.done", { list: importedList }) : t("onboarding.import.nothing"));
  const status = $derived(importStatus(importState.plan, importState.progress));
  const stepKey = $derived(status.phase ? `${status.phase.sourceId}/${status.phase.profileId}/${status.phase.kind}` : "");
  const stepLabel = $derived.by(() => {
    const phase = status.phase;
    if (!phase) return "";
    const progress = importState.progress;
    if (phase.kind === "extensions" && progress?.kind === "extensions" && progress.total > 0) {
      return t("onboarding.import.step.extensionsCount", { current: progress.done + 1, total: progress.total });
    }
    const source = sources.find((candidate) => candidate.id === phase.sourceId);
    const profile = source?.profiles.find((candidate) => candidate.id === phase.profileId);
    const from = source && profile && source.profiles.length > 1 ? profile.name : (source?.name ?? phase.sourceId);
    return t(`onboarding.import.step.${phase.kind}`, { from });
  });
  const motion = prefersReducedMotion() ? 0 : 220;
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
  // Only Chromium cookies go through the Keychain prompt worth announcing, and only while they import.
  const keychainPrompt = $derived(importState.running && status.phase?.kind === "cookies"
    && sources.find((source) => source.id === status.phase?.sourceId)?.family === "chromium");
  let advanced = $state(false);
  let continueButton = $state<HTMLButtonElement | null>(null);

  // The import runs for a while with no focus change: its outcome is spoken once, as it lands, and Continue
  // takes the focus the disabled Import button lost.
  let outcomeSpoken = untrack(() => finished);
  $effect(() => {
    if (!finished || outcomeSpoken) return;
    outcomeSpoken = true;
    announce([
      doneText,
      failures.length > 0 ? t("onboarding.import.partial", { list: failures.join(", ") }) : "",
    ].filter(Boolean).join(" "));
    queueMicrotask(() => { if (document.activeElement === document.body) continueButton?.focus({ preventScroll: true }); });
  });

  function toggle<T>(list: T[], value: T): T[] {
    return list.includes(value) ? list.filter((item) => item !== value) : [...list, value];
  }
</script>

{#snippet logo(source: ImportSourceInfo)}
  {#if source.iconDataURL}
    <img class="logo" src={source.iconDataURL} alt="" width="32" height="32" />
  {:else}
    <span class="ico" data-family={source.family} aria-hidden="true">{source.name[0]}</span>
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
      {#if source.needsFullDiskAccess}
        <button class="src locked" disabled={importState.running || finished} onclick={() => importActions.openFullDiskAccessSettings()}>
          {@render logo(source)}
          <span class="name">{source.name}<small class="hint">{t("onboarding.import.allow")}</small></span>
        </button>
      {:else}
        <button class="src" class:on aria-pressed={on} disabled={importState.running || finished}
          onclick={() => setImportChoices(toggleSource(source, choices))}>
          {@render logo(source)}
          <span class="name">{source.name}</span>
          <span class="check" aria-hidden="true">{#if on}<svg width="14" height="14" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.5 6.2l2.3 2.3 4.7-5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" /></svg>{/if}</span>
        </button>
      {/if}
    {/each}
  </div>

  {#if locked.length > 0 && !importState.running && !finished}
    <p class="note access">
      {t("onboarding.import.access", { browsers: list(locked.map((source) => source.name)) })}
      <button class="more" onclick={() => importActions.openFullDiskAccessSettings()}>{t("onboarding.import.openSettings")}</button>
    </p>
  {/if}

  <div class="ob-scroll">
    {#if importState.running}
      <div class="progress">
        <p class="step">{#key stepKey}<span transition:fade={{ duration: motion }}>{stepLabel}</span>{/key}</p>
        <span class="import-track" class:busy={status.indeterminate} role="progressbar" aria-label={t("onboarding.import.running")}
          aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(status.fraction * 100)} aria-valuetext={stepLabel}>
          <i style:transform="scaleX({status.fraction})"></i>
        </span>
      </div>
      {#if keychainPrompt}<p class="note">{t("onboarding.import.keychainNote")}</p>{/if}
    {:else if finished}
      <p class="note done">{doneText}</p>
      {#if failures.length > 0}<p class="note">{t("onboarding.import.partial", { list: failures.join(", ") })}</p>{/if}
    {:else}
      <button class="more" aria-expanded={advanced} onclick={() => (advanced = !advanced)}>
        {advanced ? t("onboarding.import.lessOptions") : t("onboarding.import.moreOptions")}
      </button>
    {/if}

    {#if advanced && !importState.running && !finished}
      <div class="advanced" transition:slide={{ duration: motion }}>
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
          {#each IMPORT_KINDS as kind (kind)}
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
  </div>
{/if}

<div class="ob-foot">
  {#if onboarding.mode === "full"}<button class="ob-btn ghost" disabled={importState.running} onclick={goBack}>{t("onboarding.back")}</button>{:else}<span></span>{/if}
  <span class="actions">
    {#if !finished && sources.length > 0}<button class="ob-btn ghost" disabled={importState.running} onclick={goNext}>{t("onboarding.skip")}</button>{/if}
    {#if finished || sources.length === 0}
      <button class="ob-btn primary" bind:this={continueButton} onclick={goNext}>{t("onboarding.continue")}</button>
    {:else}
      <button class="ob-btn primary" disabled={importState.running || chosenSources.length === 0} onclick={runSelectedImport}>
        {importState.running ? t("onboarding.import.running") : t("onboarding.import.run")}
      </button>
    {/if}
  </span>
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
  .src.locked:disabled .hint { color: var(--text-secondary); }
  .actions { display: flex; gap: 8px; }
  .ico { width: 30px; height: 30px; border-radius: var(--radius-sm); display: grid; place-items: center; color: #fff; font-weight: var(--font-weight-bold); background: #6d5ae6; flex: none; }
  .ico[data-family="safari"] { background: #2f9cf0; } .ico[data-family="firefox"] { background: #ff7139; }
  .name { flex: 1; }
  .check { color: var(--accent); font-size: var(--font-size-lg); }
  .logo { width: 32px; height: 32px; flex: none; }
  .hint { display: block; margin-top: 2px; font-size: var(--font-size-xs); font-weight: var(--font-weight-medium); color: var(--accent-ink); }
  .note { font-size: var(--font-size-sm); color: var(--text-secondary); margin: 12px 0 0; }
  .note.done { color: var(--success-text); font-weight: var(--font-weight-semibold); }
  .access .more { margin: 0; }
  .progress { margin-top: 14px; }
  /* Both labels share one cell while they crossfade. */
  .step { display: grid; margin: 0 0 8px; font-size: var(--font-size-sm); color: var(--text-secondary); }
  .step span { grid-area: 1 / 1; }
  .import-track { position: relative; display: block; height: 4px; border-radius: var(--radius-2xs); background: var(--bg-active); overflow: hidden; }
  .import-track i { display: block; height: 100%; background: var(--accent); transform-origin: left; transition: transform .6s var(--motion-ease-standard); }
  .import-track.busy::after { content: ""; position: absolute; inset: 0; transform: translateX(-100%);
    background: linear-gradient(90deg, transparent, color-mix(in srgb, var(--accent) 40%, transparent), transparent); animation: import-shimmer 1.6s ease-in-out infinite; }
  @keyframes import-shimmer { to { transform: translateX(100%); } }
  .more { border: 0; background: none; padding: 0; margin-top: 12px; font-size: var(--font-size-sm); color: var(--accent-ink); cursor: pointer; }
  .advanced { margin-top: 10px; padding: 12px; border-radius: var(--radius-lg); background: var(--bg-hover); font-size: var(--font-size-sm); color: var(--text-primary); }
  .advanced label { display: block; padding: 4px 0; }
  .lab { margin: 8px 0 6px; font-size: var(--font-size-xs); font-weight: var(--font-weight-semibold); color: var(--text-secondary); }
  .lab:first-child { margin-top: 0; }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; }
  .chip { font-size: var(--font-size-sm); padding: 4px 10px; border-radius: var(--radius-chip); border: 0; cursor: pointer; background: var(--accent-tint-14); color: var(--accent-ink); }
  .chip.off { background: var(--bg-active); color: var(--text-muted); text-decoration: line-through; }
  @media (prefers-reduced-motion: reduce) {
    .src, .import-track i { transition: none; }
    .import-track.busy::after { display: none; }
  }
</style>
