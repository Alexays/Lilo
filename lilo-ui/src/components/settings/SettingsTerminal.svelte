<script lang="ts">
  import { keepAwakeActions, settingsActions } from "../../lib/bridge/actions";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getSetting, getTerminalOptions, setSetting } from "../../stores/settings.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSelect from "../ui/UiSelect.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import { getAppNames, getKeepAwakeState, getRunningApps, neverFreezeList, withApp, withoutApp } from "../../stores/keepAwake.svelte";

  const enabled = $derived(getSetting("terminalEnabled", "true") !== "false");
  const options = $derived(getTerminalOptions());
  const themeId = $derived(getSetting("terminalTheme", "auto"));
  const themeOptions = $derived((options?.themes ?? []).map((theme) => ({ value: theme.id, label: theme.name })));
  const theme = $derived(options?.themes.find((candidate) => candidate.id === themeId) ?? options?.themes[0]);
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
  // The helper only exists while the mode is on: off, it says what turning it on does, unless
  // the build can never run it.
  const lidStatus = $derived(lidClosed || keepAwake.helperStatus === "unsigned" ? keepAwake.helperStatus : "notRegistered");
  const batteryOptions = $derived([10, 15, 20, 30, 40].map((percent) => ({ value: String(percent), label: percentFormat.format(percent / 100) })));
  const durationOptions = [2, 4, 8, 12, 24].map((hours) => ({ value: String(hours), label: `${hours} h` }));
  const addableApps = $derived(
    getRunningApps().filter((app) => !neverFreeze.includes(app.bundleId)).map((app) => ({ value: app.bundleId, label: app.name })),
  );
  const saveNeverFreeze = (list: string[]) => setSetting("terminalLidNeverFreeze", JSON.stringify(list));
  $effect(() => {
    if (lidClosed && freezeApps) keepAwakeActions.loadRunningApps();
  });
  $effect(() => {
    const unnamed = neverFreeze.filter((bundleId) => !getAppNames()[bundleId]);
    if (lidClosed && freezeApps && unnamed.length > 0) keepAwakeActions.loadAppNames(unnamed);
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
  <UiInsetList title={t("settings.terminalAppearanceGroup")}>
    <UiListRow title={t("settings.terminalTheme")} description={t("settings.terminalThemeDescription")}>
      {#snippet action()}
        <UiSelect
          value={themeId}
          options={themeOptions}
          ariaLabel={t("settings.terminalTheme")}
          onchange={(value) => setSetting("terminalTheme", value)}
        />
      {/snippet}
    </UiListRow>
    {#if theme}
      <div class="preview" style:background={theme.background} style:color={theme.foreground} aria-hidden="true">
        <div class="line">
          <span style:color={theme.palette[2]}>~/Projects</span>
          <span style:color={theme.palette[4]}>git:(main)</span>
          <span>npm run dev</span>
        </div>
        <div class="line">
          <span style:color={theme.palette[1]}>error</span>
          <span style:color={theme.palette[3]}>warning</span>
          <span style:color={theme.palette[6]}>info</span>
          <span style:color={theme.palette[8]}>dim</span>
        </div>
        <div class="palette">
          {#each theme.palette as color, index (index)}
            <span style:background={color}></span>
          {/each}
        </div>
      </div>
    {/if}
    <UiListRow title={t("settings.terminalImportTitle")} description={t("settings.terminalImportDescription")}>
      {#snippet action()}
        <UiButton onclick={() => settingsActions.importTerminalTheme()}>{t("settings.terminalImport")}</UiButton>
      {/snippet}
    </UiListRow>
    <UiListRow title={t("settings.terminalFont")} description={t("settings.terminalFontDescription")}>
      {#snippet action()}
        <UiSelect
          value={getSetting("terminalFontFamily", "")}
          options={fontOptions}
          ariaLabel={t("settings.terminalFont")}
          onchange={(value) => setSetting("terminalFontFamily", value)}
        />
      {/snippet}
    </UiListRow>
    <UiListRow title={t("settings.terminalFontSize")} description={t("settings.terminalFontSizeDescription")}>
      {#snippet action()}
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
  </UiInsetList>

  <UiInsetList title={t("settings.terminalSleepGroup")}>
    <UiListRow title={t("settings.terminalPreventSleep")} description={t("settings.terminalPreventSleepDescription")}>
      {#snippet action()}
        <UiToggle
          checked={preventSleep}
          ariaLabel={t("settings.terminalPreventSleep")}
          onchange={(value) => setSetting("terminalPreventSleep", value ? "true" : "false")}
        />
      {/snippet}
    </UiListRow>
    {#if preventSleep}
      <div class="nested">
        <UiListRow title={t("settings.terminalLidClosed")} description={t(`settings.terminalLidStatus.${lidStatus}`)}>
          {#snippet action()}
            {#if lidClosed && keepAwake.helperStatus === "requiresApproval"}
              <UiButton onclick={() => keepAwakeActions.openLoginItems()}>{t("settings.terminalLidApprove")}</UiButton>
            {/if}
            <UiToggle
              checked={lidClosed}
              disabled={keepAwake.helperStatus === "unsigned"}
              ariaLabel={t("settings.terminalLidClosed")}
              onchange={(value) => setSetting("terminalLidClosed", value ? "true" : "false")}
            />
          {/snippet}
        </UiListRow>
      </div>
      {#if lidClosed}
        <div class="nested deep">
          <UiListRow title={t("settings.terminalLidStopUnder")}>
            {#snippet action()}
              <UiSelect
                value={getSetting("terminalLidBatteryFloor", "20")}
                options={batteryOptions}
                ariaLabel={t("settings.terminalLidBatteryFloor")}
                onchange={(value) => setSetting("terminalLidBatteryFloor", value)}
              />
              <UiSelect
                value={getSetting("terminalLidMaxHours", "8")}
                options={durationOptions}
                ariaLabel={t("settings.terminalLidMaxHours")}
                onchange={(value) => setSetting("terminalLidMaxHours", value)}
              />
            {/snippet}
          </UiListRow>
        </div>
        <div class="nested deep">
          <UiListRow title={t("settings.terminalLidFreezeApps")} description={t("settings.terminalLidFreezeAppsDescription")}>
            {#snippet action()}
              <UiToggle
                checked={freezeApps}
                ariaLabel={t("settings.terminalLidFreezeApps")}
                onchange={(value) => setSetting("terminalLidFreezeApps", value ? "true" : "false")}
              />
            {/snippet}
          </UiListRow>
        </div>
        {#if freezeApps}
          <div class="nested deep">
            <UiListRow title={t("settings.terminalLidNeverFreeze")}>
              <div class="chips">
                {#each neverFreeze as bundleId (bundleId)}
                  <span class="chip">
                    {getAppNames()[bundleId] ?? bundleId}
                    <button
                      class="chip-remove"
                      type="button"
                      aria-label={t("settings.terminalLidRemoveApp", { app: getAppNames()[bundleId] ?? bundleId })}
                      onclick={() => saveNeverFreeze(withoutApp(neverFreeze, bundleId))}
                    >
                      <svg width="8" height="8" viewBox="0 0 8 8" fill="none" aria-hidden="true">
                        <path d="m1.5 1.5 5 5m0-5-5 5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
                      </svg>
                    </button>
                  </span>
                {/each}
              </div>
              {#snippet action()}
                <UiSelect
                  value=""
                  options={[{ value: "", label: t("settings.terminalLidAddApp") }, ...addableApps]}
                  ariaLabel={t("settings.terminalLidAddApp")}
                  onchange={(value) => value && saveNeverFreeze(withApp(neverFreeze, value))}
                />
              {/snippet}
            </UiListRow>
          </div>
        {/if}
      {/if}
    {/if}
  </UiInsetList>
{/if}

<style>
  .nested {
    padding-left: 16px;
    border-left: 2px solid var(--separator);
  }

  .nested.deep {
    margin-left: 18px;
  }

  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 6px;
  }

  .chip {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 4px 2px 8px;
    border-radius: var(--radius-chip);
    background: var(--bg-hover);
    color: var(--text-primary);
    font-size: var(--font-size-sm);
  }

  .chip-remove {
    display: grid;
    place-items: center;
    width: 16px;
    height: 16px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
  }

  .chip-remove:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .chip-remove:focus-visible {
    outline: var(--focus-outline);
  }

  .preview {
    margin: 4px 12px 12px;
    padding: 12px 14px;
    border-radius: var(--radius-md);
    font-family: ui-monospace, "SF Mono", monospace;
    font-size: var(--font-size-sm);
    line-height: 1.6;
    box-shadow: inset 0 0 0 1px color-mix(in srgb, currentColor 12%, transparent);
  }

  .line {
    display: flex;
    gap: 8px;
    white-space: nowrap;
    overflow: hidden;
  }

  .palette {
    display: grid;
    grid-template-columns: repeat(16, 1fr);
    gap: 4px;
    margin-top: 10px;
  }

  .palette span {
    height: 10px;
    border-radius: var(--radius-xs);
  }
</style>
