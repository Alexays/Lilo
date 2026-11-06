<script lang="ts">
  import LayoutPicker from "./LayoutPicker.svelte";
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
    openClearBrowsingData,
    openAddEditor,
    openDesignSystem,
    openDiagnostics,
    openProcessManager,
    openSettingsSubpage,
  } from "../../stores/panels.svelte";
  import {
    getContentBlockerStatus,
    getAppIcons,
    getDefaultBrowserStatus,
    getDeviceSetup,
    getSetting,
    getSitePermissions,
    getUpdaterStatus,
    getWebsiteData,
    getZoomLevels,
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
  import CallDockPicker from "./CallDockPicker.svelte";
  import PageScalePicker from "./PageScalePicker.svelte";
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

  // Seven clicks on the version row unlock the Develop menu's tools for Lilo itself, as Android's build number does.
  let versionClicks = $state(0);
  function clickVersion(event: MouseEvent): void {
    if ((event.target as HTMLElement).closest("button") || ++versionClicks !== 7) return;
    settingsActions.unlockDeveloperTools();
  }

  // Remounts the new-profile field once a profile is created, which empties it.
  let profileFieldKey = $state(0);

  const toggle = $derived(SETTING_TOGGLES[id]);
  // The Halloween version of the chosen icon: what the seasonal switch turns on.
  const seasonalPreview = $derived(
    id === "seasonalAppIcon" ? getAppIcons().find((icon) => icon.id === getSetting("appIcon", "classic"))?.seasonalDataURL : undefined,
  );
  const link = $derived(LINKS[id]);
  const permissionKey = $derived(PERMISSION_DEFAULTS[id]);
  const blockerStatus = $derived(getContentBlockerStatus());
  const lifecyclePreset = $derived(getSetting("lifecyclePreset", "balanced"));
  const deviceSetup = $derived(getDeviceSetup());
  const updater = $derived(getUpdaterStatus());
  const updateCheck = $derived(getExtensionUpdateCheck());
  const blockerSites = $derived(id === "blockerSites" ? parseBlockerSites(getSetting("contentBlockerAllowlist", "")) : []);
  const siteCount = $derived(id === "sites" ? buildSites(getSitePermissions(), getWebsiteData(), getZoomLevels()).length : 0);
  const alwaysAllowed = $derived(id === "agentAlwaysAllowed" ? parseBlockerSites(getSetting("agentAlwaysAllowedSites", "")) : []);
  const count = $derived(
    id === "sites"
      ? siteCount
      : id === "blockerSites"
        ? blockerSites.length
        : id === "searchEngines" ? parseSearchEngines(getSetting("searchEngines", "")).length : 0,
  );

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
    if (passwordManagers.length > 0) return new Intl.ListFormat(getLocale(), { type: "conjunction" }).format(passwordManagers);
    if (id === "appUpdates") {
      if (versionClicks >= 7) return t("settings.items.appUpdates.developerTools");
      // The engine follows the update status, so a report can say which WebKit ran, the system's or Lilo's fork.
      const version = updater?.webKitVersion;
      const engine = version ? ` · ${updater.webKitFork ? t("settings.items.appUpdates.webKitFork", { version }) : `WebKit ${version}`}` : "";
      if (updater && !updater.available) return t("settings.items.appUpdates.unavailable") + engine;
      if (!updater?.lastCheck) return t(settingDescriptionKey(id)) + engine;
      const time = new Intl.DateTimeFormat(getLocale(), { dateStyle: "medium", timeStyle: "short" }).format(updater.lastCheck * 1000);
      return t("settings.items.appUpdates.lastChecked", { time }) + engine;
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

{#snippet objectIcon()}
  {#if id === "newSpace"}
    <span class="object-tile" aria-hidden="true">
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M7 2.5v9M2.5 7h9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
    </span>
  {:else if id === "deviceSetup"}
    <span class="object-tile" aria-hidden="true">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
        <rect x="1.8" y="2.6" width="12.4" height="8.4" rx="1.4" /><path d="M8 11v2.4M5.4 13.4h5.2" />
      </svg>
    </span>
  {/if}
{/snippet}

{#if id === "externalLinkRules"}
  <SettingsLinkRules {title} {description} />
{:else if id === "clearData"}
  <!-- Destructive: red text, last in its box, aligned with the labels. -->
  <button class="destructive" type="button" onclick={openClearBrowsingData}>
    {t("settings.items.clearData.action")}
  </button>
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
<UiListRow {title} {description} icon={id === "newSpace" || id === "deviceSetup" ? objectIcon : undefined}>
  {#if id === "appIcon"}
    <AppIconPicker />
  {:else if id === "theme"}
    <ThemePicker />
  {:else if id === "tabPosition"}
    <LayoutPicker />
  {:else if id === "addressPlacement"}
    <LayoutPicker kind="address" />
  {:else if id === "defaultZoom"}
    <PageScalePicker kind="zoom" />
  {:else if id === "minimumFontSize"}
    <PageScalePicker kind="font" />
  {:else if id === "dockCallsInSidebar"}
    <CallDockPicker />
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
    {#if id === "littleWindowHotKey"}
      <kbd class="keycap" aria-hidden="true">⌥⌘N</kbd>
    {:else if id === "seasonalAppIcon" && seasonalPreview}
      <img class="seasonal-preview" src={seasonalPreview} alt="" width="28" height="28" />
    {:else if id === "appIcon"}
      <span class="current-choice">{t(`settings.appIcons.${getSetting("appIcon", "classic")}`)}</span>
    {/if}
    {#if toggle && id !== "dockCallsInSidebar"}
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
    {:else if id === "autoplay"}
      <UiSegmented
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
  .object-tile {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    border-radius: var(--radius-md);
    background: var(--bg-elevated);
    box-shadow: inset 0 0 0 1px var(--separator);
    color: var(--text-secondary);
  }

  .keycap {
    margin-right: var(--space-4);
  }

  .seasonal-preview {
    border-radius: var(--radius-sm);
  }

  /* On the title's line, above the icon grid. */
  :global(.ui-list-row-action:has(> .current-choice)) {
    align-self: flex-start;
  }

  .current-choice {
    color: var(--text-secondary);
    font-size: var(--font-size-md);
  }

  .destructive {
    display: block;
    width: 100%;
    padding: 11px 14px;
    border: 0;
    background: transparent;
    color: var(--danger-text);
    font-family: inherit;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    text-align: left;
    cursor: pointer;
  }

  .destructive:hover {
    background: var(--bg-hover);
  }

  .destructive:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
    margin-top: var(--space-6);
  }
</style>
