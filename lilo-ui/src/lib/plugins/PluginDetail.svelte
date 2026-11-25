<script lang="ts">
  import "../../lib/i18n/pluginCatalog";
  import UiBadge from "../../components/ui/UiBadge.svelte";
  import UiButton from "../../components/ui/UiButton.svelte";
  import UiInsetList from "../../components/ui/UiInsetList.svelte";
  import UiListRow from "../../components/ui/UiListRow.svelte";
  import { t } from "../i18n/state.svelte";
  import {
    revokePluginCapability,
    setPluginSetting,
    showPluginInFinder,
    stopPlugin,
  } from "../../stores/plugins.svelte";
  import { capabilityLabelKey, missingRequiredSettings, pluginInitial, settingValue, type PluginRow } from "./pluginModel";
  import PluginSettingField from "./PluginSettingField.svelte";
  import PluginSwitch from "./PluginSwitch.svelte";

  interface Props {
    plugin: PluginRow;
    onenable: (enabled: boolean) => boolean;
  }

  let { plugin, onenable }: Props = $props();

  const rejected = $derived(Boolean(plugin.rejectionReason));
  const missing = $derived(new Set(missingRequiredSettings(plugin).map((spec) => spec.name)));
  const capabilityLabel = (capability: string): string => {
    const key = capabilityLabelKey(capability);
    return key ? t(key) : capability;
  };
</script>

<div class="plugin-detail">
  <UiInsetList>
    <UiListRow title={plugin.title} description={plugin.version && `v${plugin.version}`}>
      {#snippet icon()}
        <span class="detail-icon">
          {#if plugin.icon}<img class="detail-icon-image" src={plugin.icon} alt="" draggable="false" />{:else}{pluginInitial(plugin)}{/if}
        </span>
      {/snippet}
      {#snippet action()}
        {#if plugin.running}<UiBadge tone="success">{t("plugins.running")}</UiBadge>{/if}
        <PluginSwitch {plugin} {onenable} />
      {/snippet}
    </UiListRow>
    {#if rejected}
      <div class="rejection" role="alert">
        <span class="rejection-title">{t("plugins.rejectedTitle")}</span>
        <span class="rejection-reason">{plugin.rejectionReason}</span>
      </div>
    {/if}
  </UiInsetList>

  {#if !rejected}
    <UiInsetList title={t("plugins.permissions")}>
      {#each plugin.capabilities as capability (capability)}
        {@const granted = plugin.grantedCapabilities.includes(capability)}
        <UiListRow title={capabilityLabel(capability)} description={granted ? undefined : t("plugins.notGranted")}>
          {#snippet action()}
            {#if granted}
              <UiButton
                variant="ghost"
                onclick={() => revokePluginCapability(plugin.id, capability)}
              >
                <span aria-hidden="true">{t("plugins.revoke")}</span>
                <span class="visually-hidden">{t("plugins.revokeLabel", { capability: capabilityLabel(capability), name: plugin.title })}</span>
              </UiButton>
            {/if}
          {/snippet}
        </UiListRow>
      {:else}
        <UiListRow title={t("plugins.noPermissions")} />
      {/each}
    </UiInsetList>

    {#if plugin.settings.length}
      <UiInsetList title={t("plugins.settings")}>
        {#each plugin.settings as spec (spec.name)}
          <div data-setting-id={`plugin:${spec.name}`}>
            <UiListRow title={spec.title} description={missing.has(spec.name) ? t("plugins.required") : undefined}>
              {#snippet action()}
                <PluginSettingField
                  {spec}
                  value={settingValue(plugin, spec)}
                  oncommit={(value) => setPluginSetting(plugin.id, spec.name, value)}
                />
              {/snippet}
            </UiListRow>
          </div>
        {/each}
      </UiInsetList>
    {/if}
  {/if}

  <UiInsetList>
    <UiListRow title={t("plugins.folder")} description={plugin.supportDir}>
      {#snippet action()}
        <UiButton onclick={() => showPluginInFinder(plugin.id)}>{t("downloadsPanel.showInFinder")}</UiButton>
      {/snippet}
    </UiListRow>
    {#if plugin.running}
      <UiListRow title={t("plugins.process")} description={t("plugins.running")}>
        {#snippet action()}
          <UiButton onclick={() => stopPlugin(plugin.id)}>{t("plugins.stop")}</UiButton>
        {/snippet}
      </UiListRow>
    {/if}
  </UiInsetList>
</div>

<style>
  .plugin-detail {
    display: grid;
    gap: 22px;
  }

  .detail-icon {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    overflow: hidden;
    border-radius: var(--radius-sm);
    background: var(--accent);
    color: var(--accent-text);
    font-size: var(--font-size-lg);
    font-weight: var(--font-weight-bold);
  }

  .detail-icon-image {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
  }

  .rejection {
    display: grid;
    gap: 2px;
    padding: 11px 14px;
    background: color-mix(in srgb, var(--danger) 8%, transparent);
  }

  .rejection-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .rejection-reason {
    color: var(--danger-text);
    font-size: var(--font-size-sm);
    overflow-wrap: anywhere;
  }

  .visually-hidden {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
</style>
