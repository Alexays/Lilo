<script lang="ts">
  import { keepAwakeActions, settingsActions } from "../../lib/bridge/actions";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getSetting, getTerminalOptions, setSetting } from "../../stores/settings.svelte";
  import SettingsGroupIcon from "./SettingsGroupIcon.svelte";
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
  <UiInsetList title={t("settings.terminalAppearanceGroup")}>
    {#snippet icon()}<SettingsGroupIcon group="settings.terminalAppearanceGroup" />{/snippet}
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
    {#snippet icon()}<SettingsGroupIcon group="settings.terminalBehaviorGroup" />{/snippet}
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
    {#snippet icon()}<SettingsGroupIcon group="settings.terminalSleepGroup" />{/snippet}
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
      {#snippet icon()}<SettingsGroupIcon group="settings.terminalLidGroup" />{/snippet}
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
