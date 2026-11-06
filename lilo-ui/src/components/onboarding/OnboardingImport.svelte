<script lang="ts">
  import { untrack } from "svelte";
  import { fade, slide } from "svelte/transition";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { announce } from "../../lib/announce";
  import { importActions } from "../../lib/bridge/actions";
  import type { ImportSourceInfo } from "../../lib/bridge/protocol";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { IMPORT_KINDS, importStatus, PASSWORD_MANAGERS, profileKey, toggleSource } from "./onboardingModel";
  import { getExtensions, installStoreExtension, isExtensionInstalling } from "../../stores/extensions.svelte";
  import { getImportState, getOnboarding, goBack, goNext, importedSummary, runSelectedImport, setImportChoices } from "../../stores/onboarding.svelte";

  const onboarding = getOnboarding();
  const importState = getImportState();
  // Opened from Settings for a password manager: the browsers stay out of it.
  const browsers = $derived(onboarding.mode !== "passwords");
  const choices = $derived(importState.choices);
  const sources = $derived(importState.sources ?? []);
  const finished = $derived(importState.summary !== null);
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
  const installed = $derived(new Set(getExtensions().map((ext) => ext.id)));
  // Two grouped lists side by side, the first one the longer.
  const managerColumns = $derived([PASSWORD_MANAGERS.slice(0, Math.ceil(PASSWORD_MANAGERS.length / 2)), PASSWORD_MANAGERS.slice(Math.ceil(PASSWORD_MANAGERS.length / 2))]);
  const canImport = $derived(browsers && !finished && sources.length > 0);
  const addedManagers = $derived(PASSWORD_MANAGERS.filter((manager) => !manager.soon && installed.has(manager.id)));
  const extensionCount = $derived(chosenExtensions.filter((ext) => choices.extensionIds.includes(ext.id)).length);
  // What the import takes, said in one sentence; its options open on request, or by themselves when nothing is left.
  const kindsSummary = $derived(new Intl.ListFormat(getLocale(), { type: "conjunction" }).format(choices.kinds.map((kind) =>
    kind === "extensions" && extensionCount > 0 ? t("onboarding.import.count.extensions", { count: extensionCount }) : t(`onboarding.import.item.${kind}`))));
  let kindsOpen = $state(false);
  const showKinds = $derived(kindsOpen || choices.kinds.length === 0);
  let managersOpen = $state(false);
  let failedIcons = $state<Record<string, true>>({});
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

  /** The profile the card imports: the first chosen one, else the one a click would choose. */
  function profileLabel(source: ImportSourceInfo): string {
    const chosen = source.profiles.filter((profile) => choices.profiles.includes(profileKey(source.id, profile.id)));
    return (chosen[0] ?? source.profiles[0])?.name ?? "";
  }
</script>

{#snippet logo(source: ImportSourceInfo)}
  {#if source.iconDataURL}
    <img class="logo" src={source.iconDataURL} alt="" width="40" height="40" />
  {:else}
    <span class="ico" data-family={source.family} aria-hidden="true">{source.name[0]}</span>
  {/if}
{/snippet}

{#snippet check()}
  <svg width="10" height="10" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.5 6.2l2.3 2.3 4.7-5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" /></svg>
{/snippet}

<div class="ob-head">
  <h2>{browsers ? t("onboarding.import.title") : t("onboarding.passwords.title")}</h2>
  <p class="ob-sub">{browsers ? t("onboarding.import.subtitle") : t("onboarding.passwords.subtitle")}</p>
</div>

<div class="ob-body">
  {#if browsers}
    {#if importState.sources === null}
      <p class="note">{t("onboarding.import.scanning")}</p>
    {:else if sources.length === 0}
      <p class="note">{t("onboarding.import.none")}</p>
    {:else}
      <div class="cards" role="group" aria-label={t("onboarding.import.title")}>
        {#each sources as source (source.id)}
          {@const on = chosenSources.includes(source)}
          {#if source.needsFullDiskAccess}
            <button class="src locked" disabled={importState.running || finished} onclick={() => importActions.openFullDiskAccessSettings()}>
              {@render logo(source)}
              <span class="ob-text">{source.name}<small class="allow">{t("onboarding.import.allow")}</small></span>
            </button>
          {:else}
            <button class="src" class:on aria-pressed={on} disabled={importState.running || finished}
              onclick={() => setImportChoices(toggleSource(source, choices))}>
              {@render logo(source)}
              <span class="ob-text">{source.name}<small>{profileLabel(source)}</small></span>
              {#if on}<span class="tick" aria-hidden="true">{@render check()}</span>{/if}
            </button>
          {/if}
        {/each}
      </div>

      <!-- What to import, then the import itself in the same place. -->
      {#if importState.running}
        <div class="progress">
          <p class="step">{#key stepKey}<span transition:fade={{ duration: motion }}>{stepLabel}</span>{/key}</p>
          <span class="import-track" class:busy={status.indeterminate} role="progressbar" aria-label={t("onboarding.import.running")}
            aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(status.fraction * 100)} aria-valuetext={stepLabel}>
            <i style:transform="scaleX({status.fraction})"></i>
          </span>
          {#if keychainPrompt}<p class="note">{t("onboarding.import.keychainNote")}</p>{/if}
        </div>
      {:else if finished}
        <div class="progress">
          <p class="note done">{doneText}</p>
          {#if failures.length > 0}<p class="note">{t("onboarding.import.partial", { list: failures.join(", ") })}</p>{/if}
        </div>
      {:else if !showKinds}
        <p class="summary">{t("onboarding.import.summary", { list: kindsSummary })}
          <button class="link" aria-expanded="false" onclick={() => (kindsOpen = true)}>{t("onboarding.import.change")}</button></p>
      {:else}
        <div class="kinds" role="group" aria-labelledby="onboarding-kinds" transition:slide={{ duration: motion }}>
          <span class="lab" id="onboarding-kinds">{t("onboarding.import.kinds")}</span>
          {#each IMPORT_KINDS as kind (kind)}
            {@const on = choices.kinds.includes(kind)}
            <button class="chip" class:on aria-pressed={on} onclick={() => setImportChoices({ ...choices, kinds: toggle(choices.kinds, kind) })}>
              {#if on}{@render check()}{/if}{t(`onboarding.import.kind.${kind}`)}
            </button>
          {/each}
        </div>
        {#each chosenSources as source (source.id)}
          {#if source.profiles.length > 1}
            <div class="options" role="group" aria-label={t("onboarding.import.profiles", { browser: source.name })}>
              <span class="lab">{t("onboarding.import.profiles", { browser: source.name })}</span>
              {#each source.profiles as profile (profile.id)}
                {@const key = profileKey(source.id, profile.id)}
                <label><input type="checkbox" checked={choices.profiles.includes(key)}
                  onchange={() => setImportChoices({ ...choices, profiles: toggle(choices.profiles, key) })} /> {profile.name}</label>
              {/each}
            </div>
          {/if}
        {/each}
        {#if choices.kinds.includes("extensions") && chosenExtensions.length > 0}
          <div class="options" role="group" aria-label={t("onboarding.import.extensions")}>
            <span class="lab">{t("onboarding.import.extensions")}</span>
            {#each chosenExtensions as ext (ext.id)}
              <label><input type="checkbox" checked={choices.extensionIds.includes(ext.id)}
                onchange={() => setImportChoices({ ...choices, extensionIds: toggle(choices.extensionIds, ext.id) })} /> {ext.name}</label>
            {/each}
          </div>
        {/if}
      {/if}
    {/if}

    <h3 class="ob-section passwords">{t("onboarding.passwords.title")}</h3>
    <div class="ob-group">
      <div class="ob-row">
        <span class="stack" aria-hidden="true">
          {#each PASSWORD_MANAGERS.filter((manager) => !manager.soon) as manager (manager.id)}
            {#if !failedIcons[manager.id]}<img src="./password-managers/{manager.id}.png" alt="" width="24" height="24" onerror={() => (failedIcons[manager.id] = true)} />{/if}
          {/each}
        </span>
        <span class="ob-text">{t("onboarding.passwords.manager")}<small>{t("onboarding.passwords.subtitle")}</small></span>
        {#if addedManagers.length > 0}<span class="ob-done">{addedManagers.map((manager) => manager.name).join(", ")}</span>{/if}
        <button class="ob-btn" aria-expanded={managersOpen} aria-controls="onboarding-managers" onclick={() => (managersOpen = !managersOpen)}>
          {t("onboarding.passwords.choose")}
        </button>
      </div>
    </div>
  {/if}

  {#if !browsers || managersOpen}
  <div class="managers" id="onboarding-managers" class:nested={browsers} transition:slide={{ duration: motion }}>
    {#each managerColumns as column, i (i)}
      <div class="ob-group" role="list">
        {#each column as manager (manager.id)}
          <div class="ob-row" class:soon={manager.soon} role="listitem">
            {#if !failedIcons[manager.id]}
              <!-- Each extension's own icon, shipped in the app bundle (scripts/generate_password_manager_icons.py). -->
              <img class="logo" src="./password-managers/{manager.id}.png" alt="" width="32" height="32"
                onerror={() => (failedIcons[manager.id] = true)} />
            {:else}
              <span class="glyph" aria-hidden="true">{manager.name[0]}</span>
            {/if}
            <span class="ob-text">{manager.name}<small>{t(`onboarding.passwords.managers.${manager.key}`)}</small></span>
            {#if manager.soon}
              <span class="soon-label">{t("onboarding.passwords.soon")}</span>
            {:else if installed.has(manager.id)}
              <span class="ob-done">{t("onboarding.passwords.added")}</span>
            {:else}
              <button class="ob-btn" aria-label={t("onboarding.passwords.addNamed", { name: manager.name })}
                disabled={isExtensionInstalling(manager.id)} onclick={() => installStoreExtension(manager.id)}>
                {isExtensionInstalling(manager.id) ? t("onboarding.passwords.adding") : t("onboarding.passwords.add")}
              </button>
            {/if}
          </div>
        {/each}
      </div>
    {/each}
  </div>
  {/if}
</div>

<div class="ob-foot">
  {#if onboarding.mode === "full"}<button class="ob-btn ghost" disabled={importState.running} onclick={goBack}>{t("onboarding.back")}</button>{:else}<span></span>{/if}
  {#if canImport}
    <button class="ob-btn ghost" disabled={importState.running} onclick={goNext}>{t("onboarding.skip")}</button>
    <button class="ob-btn primary" disabled={importState.running || chosenSources.length === 0} onclick={runSelectedImport}>
      {importState.running ? t("onboarding.import.running") : t("onboarding.import.run")}
    </button>
  {:else}
    <button class="ob-btn primary" bind:this={continueButton} onclick={goNext}>{t("onboarding.continue")}</button>
  {/if}
</div>

<style>
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; }
  .src { position: relative; display: flex; align-items: center; gap: 14px; min-height: 68px; padding: 12px 16px; border: 0; border-radius: var(--radius-box);
    background: var(--onb-surface); box-shadow: 0 0 0 .5px var(--onb-edge); color: var(--text-primary); font: inherit; text-align: left; cursor: pointer;
    transition: box-shadow var(--motion-duration-normal); }
  .src.on { background: var(--onb-surface-strong); box-shadow: 0 0 0 2px var(--accent); }
  .src:disabled { cursor: default; }
  .src:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
  .src.locked .logo, .src.locked .ico { opacity: .75; }
  .src .ob-text small.allow { color: var(--accent-ink); }
  .src.locked:disabled .ob-text small.allow { color: var(--text-secondary); }
  .tick { width: 20px; height: 20px; flex: none; display: grid; place-items: center; border-radius: 50%; background: var(--accent); color: var(--accent-text); }
  .logo { width: 40px; height: 40px; flex: none; }
  .ico { width: 40px; height: 40px; border-radius: var(--radius-md); display: grid; place-items: center; color: #fff; font-weight: var(--font-weight-bold); background: #6d5ae6; flex: none; }
  .ico[data-family="safari"] { background: #2f9cf0; } .ico[data-family="firefox"] { background: #ff7139; }

  .kinds { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 12px; }
  .lab { margin-right: 4px; font-size: var(--font-size-md); color: var(--text-secondary); }
  .chip { display: inline-flex; align-items: center; gap: 6px; height: var(--control-height-sm); padding: 0 10px; border: 0; border-radius: var(--radius-sm);
    background: transparent; box-shadow: inset 0 0 0 1px var(--onb-edge); color: var(--text-secondary); font: inherit; font-size: var(--font-size-md); cursor: pointer; }
  .chip.on { background: var(--onb-surface-strong); color: var(--text-primary); }
  .chip.on svg { color: var(--accent); }
  .chip:focus-visible { outline: var(--focus-outline); outline-offset: 1px; }
  .options { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 16px; margin-top: 10px; font-size: var(--font-size-md); color: var(--text-primary); }
  .options label { display: inline-flex; align-items: center; gap: 6px; }

  .progress { margin-top: 16px; max-width: 560px; }
  .note { margin: 8px 0 0; font-size: var(--font-size-md); color: var(--text-secondary); }
  .note.done { margin: 0; color: var(--success-text); font-weight: var(--font-weight-semibold); }
  /* Both labels share one cell while they crossfade. */
  .step { display: grid; margin: 0 0 8px; font-size: var(--font-size-md); color: var(--text-secondary); }
  .step span { grid-area: 1 / 1; }
  .import-track { position: relative; display: block; height: 4px; border-radius: var(--radius-2xs); background: var(--onb-edge); overflow: hidden; }
  .import-track i { display: block; height: 100%; background: var(--accent); transform-origin: left; transition: transform var(--motion-duration-slow) var(--motion-ease-standard); }
  .import-track.busy::after { content: ""; position: absolute; inset: 0; transform: translateX(-100%);
    background: linear-gradient(90deg, transparent, color-mix(in srgb, var(--accent) 40%, transparent), transparent); animation: import-shimmer 1.6s ease-in-out infinite; }
  @keyframes import-shimmer { to { transform: translateX(100%); } }

  .summary { margin: 12px 0 0; font-size: var(--font-size-md); color: var(--text-secondary); }
  .link { margin-left: 4px; padding: 0; border: 0; background: none; color: var(--accent-ink); font: inherit; font-weight: var(--font-weight-medium); cursor: pointer; }
  .link:focus-visible { outline: var(--focus-outline); outline-offset: 2px; border-radius: var(--radius-xs); }
  h3.ob-section.passwords { margin-top: 32px; }
  .stack { display: flex; flex: none; }
  .stack img { width: 24px; height: 24px; border-radius: var(--radius-xs); box-shadow: 0 0 0 2px var(--onb-surface-strong); }
  .stack img + img { margin-left: -4px; }
  .managers.nested { margin-top: 12px; }
  .managers { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 16px; align-items: start; }
  .ob-row .logo { width: 32px; height: 32px; }
  .ob-row.soon .logo, .ob-row.soon .glyph { opacity: .6; }
  .glyph { width: 32px; height: 32px; flex: none; display: grid; place-items: center; border-radius: var(--radius-sm); font-weight: var(--font-weight-bold);
    background: var(--accent-tint-14); color: var(--accent); }
  .soon-label { font-size: var(--font-size-sm); color: var(--text-secondary); }
  @media (prefers-reduced-motion: reduce) {
    .src, .import-track i { transition: none; }
    .import-track.busy::after { display: none; }
  }
</style>
