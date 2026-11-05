<script lang="ts">
  import { keepAwakeActions, settingsActions } from "../../lib/bridge/actions";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getSetting, getTerminalOptions, setSetting } from "../../stores/settings.svelte";
  import UiBadge from "../ui/UiBadge.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiChip from "../ui/UiChip.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";
  import UiSelect from "../ui/UiSelect.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import { getAppNames, getKeepAwakeState, getRunningApps, neverFreezeList, withApp, withoutApp } from "../../stores/keepAwake.svelte";

  const enabled = $derived(getSetting("terminalEnabled", "true") !== "false");
  const options = $derived(getTerminalOptions());
  const themeId = $derived(getSetting("terminalTheme", "auto"));
  // An id no longer in the list (a removed import) falls back to the first theme, as the terminal does.
  const selectedTheme = $derived(options?.themes.some((theme) => theme.id === themeId) ? themeId : options?.themes[0]?.id);
  const fontOptions = $derived([
    { value: "", label: t("settings.terminalFontSystem") },
    ...(options?.ghosttyFont ? [{ value: "ghostty", label: `Ghostty (${options.ghosttyFont})` }] : []),
    ...(options?.fonts ?? []).map((family) => ({ value: family, label: family })),
  ]);
  const optionKeyOptions = $derived([
    { value: "", label: t("settings.terminalOptionTypes") },
    { value: "left", label: t("settings.terminalOptionLeft") },
    { value: "right", label: t("settings.terminalOptionRight") },
    { value: "both", label: t("settings.terminalOptionBoth") },
  ]);
  const megabytesFormat = $derived(new Intl.NumberFormat(getLocale(), { style: "unit", unit: "megabyte" }));
  const percentFormat = $derived(new Intl.NumberFormat(getLocale(), { style: "percent" }));
  const scrollbackOptions = $derived([2, 10, 50, 200].map((megabytes) => ({ value: String(megabytes), label: megabytesFormat.format(megabytes) })));
  const sizeOptions = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22].map((size) => ({ value: String(size), label: `${size} pt` }));
  const preventSleep = $derived(getSetting("terminalPreventSleep", "true") !== "false");
  const lidClosed = $derived(getSetting("terminalLidClosed", "false") === "true");
  const freezeApps = $derived(getSetting("terminalLidFreezeApps", "true") !== "false");
  const neverFreeze = $derived(neverFreezeList(getSetting("terminalLidNeverFreeze", "")));
  const keepAwake = $derived(getKeepAwakeState());
  // Off keeps the lid choice for next time, as the two switches did; a build that can never run the helper has no lid mode.
  const sleepMode = $derived(!preventSleep ? "off" : lidClosed && keepAwake.helperStatus !== "unsigned" ? "lid" : "command");
  const sleepModes = $derived(keepAwake.helperStatus === "unsigned" ? ["off", "command"] : ["off", "command", "lid"]);
  function setSleepMode(mode: string): void {
    setSetting("terminalPreventSleep", mode === "off" ? "false" : "true");
    if (mode !== "off") setSetting("terminalLidClosed", mode === "lid" ? "true" : "false");
  }
  const batteryOptions = $derived([10, 15, 20, 30, 40].map((percent) => ({ value: String(percent), label: percentFormat.format(percent / 100) })));
  const durationOptions = [2, 4, 8, 12, 24].map((hours) => ({ value: String(hours), label: `${hours} h` }));
  const addableApps = $derived(
    getRunningApps().filter((app) => !neverFreeze.includes(app.bundleId)).map((app) => ({ value: app.bundleId, label: app.name })),
  );
  const saveNeverFreeze = (list: string[]) => setSetting("terminalLidNeverFreeze", JSON.stringify(list));
  $effect(() => {
    if (sleepMode === "lid" && freezeApps) keepAwakeActions.loadRunningApps();
  });
  $effect(() => {
    const unnamed = neverFreeze.filter((bundleId) => !getAppNames()[bundleId]);
    if (sleepMode === "lid" && freezeApps && unnamed.length > 0) keepAwakeActions.loadAppNames(unnamed);
  });
</script>

<UiInsetList>
  <UiListRow title={t("settings.terminalEnabled")} description={t("settings.terminalEnabledDescription")}>
    {#snippet action()}
      <UiToggle
        checked={enabled}
        ariaLabel={t("settings.terminalEnabled")}
        onchange={(value) => setSetting("terminalEnabled", value ? "true" : "false")}
      />
    {/snippet}
  </UiListRow>
</UiInsetList>

{#if enabled}
  <UiInsetList title={t("settings.terminalTheme")} boxed={false}>
    {#snippet accessory()}{t("settings.terminalThemeDescription")}{/snippet}
    <div class="themes" role="radiogroup" aria-label={t("settings.terminalTheme")}>
      {#each options?.themes ?? [] as theme (theme.id)}
        <button
          class="theme"
          class:on={theme.id === selectedTheme}
          role="radio"
          aria-checked={theme.id === selectedTheme}
          onclick={() => setSetting("terminalTheme", theme.id)}
        >
          <!-- Drawn from the theme's own colors: its foreground and palette on its background. -->
          <span class="shot" style:background={theme.background} aria-hidden="true">
            <span class="bars">
              <i style:background={theme.palette[2]}></i><i style:background={theme.palette[4]}></i><i style:background={theme.foreground}></i>
            </span>
            <span class="bars">
              <i style:background={theme.palette[1]}></i><i style:background={theme.foreground}></i><i style:background={theme.palette[3]}></i>
            </span>
            <span class="bars">
              <i style:background={theme.palette[4]}></i><i style:background={theme.foreground}></i>
            </span>
            <span class="swatches">
              {#each theme.palette.slice(1, 7) as color, index (index)}<i style:background={color}></i>{/each}
            </span>
          </span>
          {theme.name}
        </button>
      {/each}
      <button class="theme" onclick={() => settingsActions.importTerminalTheme()}>
        <span class="shot import" aria-hidden="true">
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M7 2.5v9M2.5 7h9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
        </span>
        {t("settings.terminalImport")}
      </button>
    </div>
    <p class="caption">{t("settings.terminalImportCaption")}</p>
  </UiInsetList>

  <UiInsetList>
    <UiListRow title={t("settings.terminalFont")} description={t("settings.terminalFontDescription")}>
      {#snippet action()}
        <UiSelect
          value={getSetting("terminalFontFamily", "")}
          options={fontOptions}
          ariaLabel={t("settings.terminalFont")}
          onchange={(value) => setSetting("terminalFontFamily", value)}
        />
        <UiSelect
          value={getSetting("terminalFontSize", "13")}
          options={sizeOptions}
          ariaLabel={t("settings.terminalFontSize")}
          onchange={(value) => setSetting("terminalFontSize", value)}
        />
      {/snippet}
    </UiListRow>
  </UiInsetList>

  <UiInsetList title={t("settings.terminalBehaviorGroup")}>
    <UiListRow title={t("settings.terminalScrollback")} description={t("settings.terminalScrollbackDescription")}>
      {#snippet action()}
        <UiSelect
          value={getSetting("terminalScrollbackMB", "10")}
          options={scrollbackOptions}
          ariaLabel={t("settings.terminalScrollback")}
          onchange={(value) => setSetting("terminalScrollbackMB", value)}
        />
      {/snippet}
    </UiListRow>
    <UiListRow title={t("settings.terminalNotify")} description={t("settings.terminalNotifyDescription")}>
      {#snippet action()}
        <UiToggle
          checked={getSetting("terminalNotifyLongCommands", "true") !== "false"}
          ariaLabel={t("settings.terminalNotify")}
          onchange={(enabled) => setSetting("terminalNotifyLongCommands", enabled ? "true" : "false")}
        />
      {/snippet}
    </UiListRow>
    <UiListRow title={t("settings.terminalOptionKey")} description={t("settings.terminalOptionKeyDescription")}>
      {#snippet action()}
        <UiSelect
          value={getSetting("terminalOptionAsMeta", "")}
          options={optionKeyOptions}
          ariaLabel={t("settings.terminalOptionKey")}
          onchange={(value) => setSetting("terminalOptionAsMeta", value)}
        />
      {/snippet}
    </UiListRow>
    <UiListRow
      title={t("settings.terminalSleepMode")}
      description={keepAwake.helperStatus === "unsigned" ? t("settings.terminalLidStatus.unsigned") : t("settings.terminalPreventSleepDescription")}
    >
      {#snippet action()}
        <UiSegmented
          value={sleepMode}
          options={sleepModes.map((mode) => ({ value: mode, label: t(`settings.terminalSleepModes.${mode}`) }))}
          ariaLabel={t("settings.terminalSleepMode")}
          onchange={setSleepMode}
        />
      {/snippet}
    </UiListRow>
  </UiInsetList>

  {#if sleepMode === "lid"}
    <UiInsetList title={t("settings.terminalLidGroup")}>
      <UiListRow
        title={t("settings.terminalLidHelper")}
        description={keepAwake.helperStatus === "enabled" ? undefined : t(`settings.terminalLidStatus.${keepAwake.helperStatus}`)}
      >
        {#snippet action()}
          <UiBadge tone={keepAwake.helperStatus === "enabled" ? "success" : keepAwake.helperStatus === "notFound" ? "danger" : "neutral"}>
            {t(`settings.terminalLidBadge.${keepAwake.helperStatus}`)}
          </UiBadge>
          {#if keepAwake.helperStatus === "requiresApproval"}
            <UiButton onclick={() => keepAwakeActions.openLoginItems()}>{t("settings.terminalLidApprove")}</UiButton>
          {/if}
        {/snippet}
      </UiListRow>
      <UiListRow title={t("settings.terminalLidBatteryFloor")}>
        {#snippet action()}
          <UiSelect
            value={getSetting("terminalLidBatteryFloor", "20")}
            options={batteryOptions}
            ariaLabel={t("settings.terminalLidBatteryFloor")}
            onchange={(value) => setSetting("terminalLidBatteryFloor", value)}
          />
        {/snippet}
      </UiListRow>
      <UiListRow title={t("settings.terminalLidMaxHours")}>
        {#snippet action()}
          <UiSelect
            value={getSetting("terminalLidMaxHours", "8")}
            options={durationOptions}
            ariaLabel={t("settings.terminalLidMaxHours")}
            onchange={(value) => setSetting("terminalLidMaxHours", value)}
          />
        {/snippet}
      </UiListRow>
      <UiListRow title={t("settings.terminalLidFreezeApps")} description={t("settings.terminalLidFreezeAppsDescription")}>
        {#snippet action()}
          <UiToggle
            checked={freezeApps}
            ariaLabel={t("settings.terminalLidFreezeApps")}
            onchange={(value) => setSetting("terminalLidFreezeApps", value ? "true" : "false")}
          />
        {/snippet}
      </UiListRow>
      {#if freezeApps}
        <UiListRow title={t("settings.terminalLidNeverFreeze")}>
          {#if neverFreeze.length > 0}
            <span class="chips">
              {#each neverFreeze as bundleId (bundleId)}
                <UiChip
                  label={getAppNames()[bundleId] ?? bundleId}
                  removeLabel={t("settings.terminalLidRemoveApp", { app: getAppNames()[bundleId] ?? bundleId })}
                  onremove={() => saveNeverFreeze(withoutApp(neverFreeze, bundleId))}
                />
              {/each}
            </span>
          {/if}
          {#snippet action()}
            <UiSelect
              value=""
              options={[{ value: "", label: t("settings.terminalLidAddApp") }, ...addableApps]}
              ariaLabel={t("settings.terminalLidAddApp")}
              onchange={(value) => value && saveNeverFreeze(withApp(neverFreeze, value))}
            />
          {/snippet}
        </UiListRow>
      {/if}
    </UiInsetList>
  {/if}
{/if}

<style>
  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
    margin-top: var(--space-6);
  }

  .themes {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(112px, 1fr));
    gap: var(--space-16) var(--space-16);
  }

  .theme {
    display: grid;
    /* Packed at the top: a stretched track would grow the thumbnail through its aspect ratio when a long name wraps. */
    align-content: start;
    gap: var(--space-6);
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
    font-weight: var(--font-weight-semibold);
  }

  .theme:focus-visible {
    outline: none;
  }

  .theme:focus-visible .shot {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .shot {
    display: grid;
    align-content: center;
    gap: var(--space-6);
    aspect-ratio: 5 / 2;
    padding: var(--space-8) var(--space-12);
    border-radius: var(--radius-md);
    box-shadow: inset 0 0 0 1px var(--separator);
  }

  .theme.on .shot {
    box-shadow: 0 0 0 2px var(--accent);
  }

  .bars,
  .swatches {
    display: flex;
    gap: var(--space-4);
  }

  .bars i {
    width: 18%;
    height: 3px;
    border-radius: var(--radius-2xs);
  }

  .bars i:last-child {
    width: 30%;
  }

  .swatches {
    margin-top: var(--space-2);
  }

  .swatches i {
    width: 8px;
    height: 8px;
    border-radius: var(--radius-2xs);
  }

  .shot.import {
    place-items: center;
    box-shadow: none;
    border: 1px dashed color-mix(in srgb, var(--text-primary) 22%, transparent);
    color: var(--text-secondary);
  }

  .caption {
    margin: var(--space-4) 4px 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }
</style>
