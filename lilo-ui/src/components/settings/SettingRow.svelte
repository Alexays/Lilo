<script lang="ts">
  import TabPositionPicker from "./TabPositionPicker.svelte";
  import { getAddressPlacement, isAddressLocked, setAddressPlacement } from "../../stores/tabLayout.svelte";
  import type { AddressPlacement } from "../../lib/bridge";
  import { extensionActions, profileActions, settingsActions } from "../../lib/bridge/actions";
  import { isAgentsSpace } from "../../stores/agents.svelte";
  import { getLocale, setLocale, t } from "../../lib/i18n/state.svelte";
  import { isSupportedLocale, SUPPORTED_LOCALES } from "../../lib/i18n/translate";
  import { parseSearchEngines } from "../../lib/searchEngineModel";
  import {
    checkExtensionUpdates,
    getExtensionUpdateCheck,
  } from "../../stores/extensions.svelte";
  import { PASSWORD_MANAGERS } from "../onboarding/onboardingModel";
  import { getExtensions } from "../../stores/extensions.svelte";
  import { startOnboarding } from "../../stores/onboarding.svelte";
  import {
    closeSettingsShell,
    openAddEditor,
    openDesignSystem,
    openDiagnostics,
    openProcessManager,
    openSettingsSubpage,
  } from "../../stores/panels.svelte";
  import {
    getContentBlockerStatus,
    getDefaultBrowserStatus,
    getDeviceSetup,
    getSetting,
    getSitePermissions,
    getUpdaterStatus,
    getWebsiteData,
    getZoomLevels,
    setClearDataSheetOpen,
    setSetting,
  } from "../../stores/settings.svelte";
  import { getSpaces } from "../../stores/spaces.svelte";
  import {
    buildSites,
    formatDownloadsFolderLabel,
    parseBlockerSites,
    SETTING_TOGGLES,
    type SettingId,
    settingDescriptionKey,
    settingTitleKey,
  } from "./settingsPanelModel";
  import AppIconPicker from "./AppIconPicker.svelte";
  import SettingsLinkRules from "./SettingsLinkRules.svelte";
  import ThemePicker from "./ThemePicker.svelte";
  import UiBadge from "../ui/UiBadge.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiChip from "../ui/UiChip.svelte";
  import UiLinkRow from "../ui/UiLinkRow.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";
  import UiSelect from "../ui/UiSelect.svelte";
  import UiTextField from "../ui/UiTextField.svelte";
  import UiToggle from "../ui/UiToggle.svelte";

  interface Props {
    id: SettingId;
  }

  let { id }: Props = $props();

  // Rows that open a page.
  const LINKS: Partial<Record<SettingId, () => void>> = {
    searchEngines: () => openSettingsSubpage("general", "engines"),
    shortcuts: () => openSettingsSubpage("general", "shortcuts"),
    sites: () => openSettingsSubpage("privacy", "sites"),
    blockerSites: () => openSettingsSubpage("privacy", "blockerSites"),
    processManager: openProcessManager,
    diagnostics: openDiagnostics,
    designSystem: openDesignSystem,
  };

  // Default answer to a site asking for a permission, by setting.
  const PERMISSION_DEFAULTS: Partial<Record<SettingId, string>> = {
    permissionNotifications: "permissionDefault.notifications",
    permissionMedia: "permissionDefault.media",
    permissionLocation: "permissionDefault.location",
  };

  const LIFECYCLE_PRESETS = ["conservative", "balanced", "aggressive"];
  const ZOOM_LEVELS = ["0.75", "0.9", "1.0", "1.1", "1.25", "1.5"];
  const MINIMUM_FONT_SIZES = ["0", "9", "12", "14", "16", "18", "24"];

  // Seven clicks on the version row unlock the Develop menu's tools for Lilo itself, as Android's build number does.
  let versionClicks = $state(0);
  function clickVersion(event: MouseEvent): void {
    if ((event.target as HTMLElement).closest("button") || ++versionClicks !== 7) return;
    settingsActions.unlockDeveloperTools();
  }

  // Remounts the new-profile field once a profile is created, which empties it.
  let profileFieldKey = $state(0);

  const toggle = $derived(SETTING_TOGGLES[id]);
  const link = $derived(LINKS[id]);
  const permissionKey = $derived(PERMISSION_DEFAULTS[id]);
  const blockerStatus = $derived(getContentBlockerStatus());
  const percentFormat = $derived(new Intl.NumberFormat(getLocale(), { style: "percent" }));
  const lifecyclePreset = $derived(getSetting("lifecyclePreset", "balanced"));
  const deviceSetup = $derived(getDeviceSetup());
  const updater = $derived(getUpdaterStatus());
  const updateCheck = $derived(getExtensionUpdateCheck());
  const blockerSites = $derived(id === "blockerSites" ? parseBlockerSites(getSetting("contentBlockerAllowlist", "")) : []);
  const siteCount = $derived(id === "sites" ? buildSites(getSitePermissions(), getWebsiteData(), getZoomLevels()).length : 0);
  const alwaysAllowed = $derived(id === "agentAlwaysAllowed" ? parseBlockerSites(getSetting("agentAlwaysAllowedSites", "")) : []);
  const count = $derived(id === "sites" ? siteCount : id === "blockerSites" ? blockerSites.length : 0);

  // The passwords row names the manager the user already has, by its own short name rather than its store title.
  const passwordManagers = $derived(
    id === "passwordManager"
      ? PASSWORD_MANAGERS.filter((manager) => getExtensions().some((extension) => extension.id === manager.id && extension.isEnabled)).map((manager) => manager.name)
      : [],
  );

  // The memory row describes the preset in effect, the device row the displays connected now and
  // what is remembered for them, and the version row the build running.
  const title = $derived.by(() => {
    if (id === "deviceSetup") return deviceSetup.label || t("settings.devices.builtinOnly");
    if (id === "appUpdates") return t("settings.items.appUpdates.title", { version: updater?.version ?? "" });
    if (passwordManagers.length > 0) return t("settings.items.passwordManager.installedTitle");
    return t(settingTitleKey(id));
  });
  const description = $derived.by(() => {
    if (id === "lifecyclePreset") return t(`settings.lifecycle.${lifecyclePreset}Desc`);
    if (id === "addressPlacement" && isAddressLocked()) return t("settings.items.addressPlacement.lockedRight");
    if (passwordManagers.length > 0) return new Intl.ListFormat(getLocale(), { type: "conjunction" }).format(passwordManagers);
    if (id === "appUpdates") {
      if (versionClicks >= 7) return t("settings.items.appUpdates.developerTools");
      if (updater && !updater.available) return t("settings.items.appUpdates.unavailable");
      if (!updater?.lastCheck) return t(settingDescriptionKey(id));
      const time = new Intl.DateTimeFormat(getLocale(), { dateStyle: "medium", timeStyle: "short" }).format(updater.lastCheck * 1000);
      return t("settings.items.appUpdates.lastChecked", { time });
    }
    if (id === "checkExtensionUpdates") {
      if (updateCheck.checking) return t("settings.extensionUpdates.checking");
      if (!updateCheck.lastCheck) return t(settingDescriptionKey(id));
      const parts = [
        updateCheck.updated
          ? t("settings.extensionUpdates.updated", { count: updateCheck.updated })
          : updateCheck.available
            ? t("settings.extensionUpdates.available", { count: updateCheck.available })
            : t("settings.extensionUpdates.upToDate"),
      ];
      if (updateCheck.failed) parts.push(t("settings.extensionUpdates.failed", { count: updateCheck.failed }));
      const time = new Intl.DateTimeFormat(getLocale(), { timeStyle: "short" }).format(updateCheck.lastCheck * 1000);
      parts.push(t("settings.extensionUpdates.lastChecked", { time }));
      return parts.join(" · ");
    }
    if (id === "filterLists" && blockerStatus) {
      if (!blockerStatus.updated) return t(settingDescriptionKey(id));
      const updated = new Intl.DateTimeFormat(getLocale(), { dateStyle: "medium", timeStyle: "short" })
        .format(blockerStatus.updated * 1000);
      return [t("settings.filterLists.summary", { lists: blockerStatus.lists }), t("settings.filterLists.updated", { time: updated })].join(" · ");
    }
    if (id !== "deviceSetup") return t(settingDescriptionKey(id));
    const remembered = (["camera", "input", "output"] as const)
      .filter((role) => deviceSetup[role])
      .map((role) => t(`settings.devices.${role}`, { name: deviceSetup[role] ?? "" }));
    return remembered.length > 0 ? remembered.join(" · ") : t("settings.devices.nothingYet");
  });

  function changeLocale(value: string): void {
    if (!isSupportedLocale(value)) return;
    setLocale(value);
    setSetting("locale", value);
  }
</script>

{#if id === "externalLinkRules"}
  <SettingsLinkRules {title} {description} />
{:else if link}
  <UiLinkRow {title} {description} {count} onclick={link} />
{:else if id === "appUpdates"}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div onclick={clickVersion}>
    <UiListRow {title} {description}>
      {#snippet action()}
        <UiButton disabled={!updater?.available} onclick={() => settingsActions.checkForUpdates()}>{t("settings.items.appUpdates.check")}</UiButton>
      {/snippet}
    </UiListRow>
  </div>
{:else}
<UiListRow {title} {description}>
  {#if id === "appIcon"}
    <AppIconPicker />
  {:else if id === "theme"}
    <ThemePicker />
  {:else if id === "tabPosition"}
    <TabPositionPicker />
  {:else if id === "blockerAllowedDomains"}
    <UiTextField
      value={getSetting("contentBlockerAllowedDomains", "")}
      placeholder={t("settings.items.blockerAllowedDomains.placeholder")}
      ariaLabel={title}
      oncommit={(value) => setSetting("contentBlockerAllowedDomains", value.trim())}
    />
  {:else if id === "agentAlwaysAllowed"}
    <span class="chips">
      {#each alwaysAllowed as host (host)}
        <UiChip
          label={host}
          removeLabel={t("settings.items.agentAlwaysAllowed.remove", { host })}
          onremove={() => setSetting("agentAlwaysAllowedSites", JSON.stringify(alwaysAllowed.filter((entry) => entry !== host)))}
        />
      {/each}
    </span>
  {:else if id === "newProfile"}
    {#key profileFieldKey}
      <UiTextField
        placeholder={t("settings.items.newProfile.placeholder")}
        ariaLabel={title}
        oncommit={(value) => {
          if (!value.trim()) return;
          profileActions.create(value.trim());
          profileFieldKey += 1;
        }}
      />
    {/key}
  {/if}
  {#snippet action()}
    {#if toggle}
      <UiToggle
        ariaLabel={title}
        checked={getSetting(toggle.key, String(toggle.fallback)) === "true"}
        onchange={(checked) => setSetting(toggle.key, checked ? "true" : "false")}
      />
    {:else if permissionKey}
      <UiSelect
        value={getSetting(permissionKey, "ask")}
        options={[
          { value: "ask", label: t("settings.permissionDefaults.ask") },
          { value: "block", label: t("settings.permissionDefaults.block") },
        ]}
        ariaLabel={title}
        onchange={(value) => setSetting(permissionKey, value)}
      />
    {:else if id === "defaultBrowser"}
      {#if getDefaultBrowserStatus().isDefault}
        <UiBadge tone="success">{t("settings.defaultBrowserActive")}</UiBadge>
      {:else}
        <UiButton variant="primary" onclick={() => settingsActions.setDefaultBrowser()}>
          {t("settings.defaultBrowserSet")}
        </UiButton>
      {/if}
    {:else if id === "importBrowsers"}
      <UiButton onclick={() => { closeSettingsShell(); startOnboarding("import"); }}>{t("settings.importBrowsersAction")}</UiButton>
    {:else if id === "passwordManager"}
      <UiButton onclick={() => { closeSettingsShell(); startOnboarding("passwords"); }}>{t(passwordManagers.length > 0 ? "settings.passwordManagerChange" : "settings.passwordManagerAction")}</UiButton>
    {:else if id === "replayOnboarding"}
      <UiButton onclick={() => { closeSettingsShell(); startOnboarding("full"); }}>{t("settings.replayOnboardingAction")}</UiButton>
    {:else if id === "language"}
      <UiSelect
        value={getLocale()}
        options={SUPPORTED_LOCALES.map((entry) => ({ value: entry.code, label: entry.label }))}
        ariaLabel={title}
        onchange={changeLocale}
      />
    {:else if id === "externalLinkDefault"}
      <UiSelect
        value={getSetting("externalLinkDefault", "current")}
        options={[
          { value: "current", label: t("settings.linkRules.currentSpace") },
          { value: "little", label: t("settings.linkRules.littleWindow") },
          ...getSpaces()
            .filter((space) => !space.isPrivate && !isAgentsSpace(space.id))
            .map((space) => ({ value: space.id, label: `${space.icon} ${space.name}` })),
        ]}
        ariaLabel={title}
        onchange={(value) => setSetting("externalLinkDefault", value)}
      />
    {:else if id === "searchEngine"}
      <UiSelect
        value={getSetting("searchEngine", "google")}
        options={parseSearchEngines(getSetting("searchEngines", "")).map((engine) => ({ value: engine.id, label: engine.name }))}
        ariaLabel={title}
        onchange={(value) => setSetting("searchEngine", value)}
      />
    {:else if id === "downloadsFolder"}
      <UiButton onclick={() => settingsActions.chooseDownloadsFolder()}>
        {formatDownloadsFolderLabel(getSetting("downloadsFolder", ""), t("settings.downloadsFolderFallback"))}
      </UiButton>
    {:else if id === "addressPlacement"}
      <UiSegmented
        value={getAddressPlacement()}
        options={["tabs", "page"].map((placement) => ({ value: placement, label: t(`settings.addressPlacement.${placement}`) }))}
        ariaLabel={title}
        disabled={isAddressLocked()}
        onchange={(value) => setAddressPlacement(value as AddressPlacement)}
      />
    {:else if id === "autoplay"}
      <UiSelect
        value={getSetting("autoplayPolicy", "audio")}
        options={["audio", "all", "none"].map((policy) => ({ value: policy, label: t(`settings.autoplay.${policy}`) }))}
        ariaLabel={title}
        onchange={(value) => setSetting("autoplayPolicy", value)}
      />
    {:else if id === "autoUpdate"}
      <UiToggle
        ariaLabel={title}
        disabled={!updater?.available}
        checked={updater?.automatic ?? false}
        onchange={(checked) => settingsActions.setAutomaticUpdates(checked)}
      />
    {:else if id === "defaultZoom"}
      <UiSelect
        value={getSetting("defaultZoom", "1.0")}
        options={ZOOM_LEVELS.map((level) => ({ value: level, label: percentFormat.format(Number(level)) }))}
        ariaLabel={title}
        onchange={(value) => setSetting("defaultZoom", value)}
      />
    {:else if id === "minimumFontSize"}
      <UiSelect
        value={getSetting("minimumFontSize", "0")}
        options={MINIMUM_FONT_SIZES.map((size) => ({
          value: size,
          label: size === "0" ? t("settings.items.minimumFontSize.none") : t("settings.items.minimumFontSize.points", { size }),
        }))}
        ariaLabel={title}
        onchange={(value) => setSetting("minimumFontSize", value)}
      />
    {:else if id === "folderAutoLock"}
      <UiSelect
        value={getSetting("folderAutoLockMinutes", "15")}
        options={["5", "15", "30", "60"].map((minutes) => ({ value: minutes, label: t("settings.folderAutoLock.minutes", { count: minutes }) }))}
        ariaLabel={title}
        onchange={(value) => setSetting("folderAutoLockMinutes", value)}
      />
    {:else if id === "lifecyclePreset"}
      <UiSegmented
        value={lifecyclePreset}
        options={LIFECYCLE_PRESETS.map((preset) => ({ value: preset, label: t(`settings.lifecycle.${preset}`) }))}
        ariaLabel={title}
        onchange={(value) => setSetting("lifecyclePreset", value)}
      />
    {:else if id === "clearData"}
      <UiButton variant="danger" onclick={() => setClearDataSheetOpen(true)}>{t("settings.clearData.open")}</UiButton>
    {:else if id === "newSpace"}
      <UiButton onclick={openAddEditor}>{t("settings.items.newSpace.action")}</UiButton>
    {:else if id === "filterLists"}
      <UiButton busy={blockerStatus?.updating} onclick={() => settingsActions.updateFilterLists()}>
        {t("settings.filterLists.update")}
      </UiButton>
    {:else if id === "checkExtensionUpdates"}
      <UiButton disabled={updateCheck.checking} onclick={checkExtensionUpdates}>{t("settings.extensionUpdates.checkNow")}</UiButton>
    {:else if id === "loadUnpacked"}
      <UiButton onclick={() => extensionActions.loadUnpacked()}>{t("extensions.loadUnpacked")}</UiButton>
    {:else if id === "deviceSetup"}
      <UiButton onclick={() => settingsActions.forgetDeviceSetup()}>{t("settings.devices.forget")}</UiButton>
    {/if}
  {/snippet}
</UiListRow>
{/if}

<style>
  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
    margin-top: var(--space-6);
  }
</style>
