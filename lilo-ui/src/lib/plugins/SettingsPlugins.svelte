<script lang="ts">
  import "../../lib/i18n/pluginCatalog";
  import UiButton from "../../components/ui/UiButton.svelte";
  import UiInsetList from "../../components/ui/UiInsetList.svelte";
  import UiModal from "../../components/ui/UiModal.svelte";
  import { closeSettingsSubpage, openSettingsSubpage } from "../../stores/panels.svelte";
  import { arePluginsLoaded, getPlugin, getPlugins, setPluginEnabled } from "../../stores/plugins.svelte";
  import { t } from "../i18n/state.svelte";
  import { capabilityLabelKey, ungrantedCapabilities, type PluginRow } from "./pluginModel";
  import PluginDetail from "./PluginDetail.svelte";
  import PluginListRow from "./PluginListRow.svelte";

  let { subpage }: { subpage: string | null } = $props();

  const plugins = $derived(getPlugins());
  const detailId = $derived(subpage?.startsWith("plugin:") ? subpage.slice("plugin:".length) : null);
  const detail = $derived(detailId ? getPlugin(detailId) : undefined);
  // The plugin whose permissions the sheet asks the user to allow before it starts.
  let grantingId = $state<string | null>(null);
  const granting = $derived(grantingId ? getPlugin(grantingId) : undefined);
  const grantList = $derived(granting ? ungrantedCapabilities(granting) : []);

  // Removed from its folder while its page is open: fall back to the list.
  $effect(() => {
    if (detailId && arePluginsLoaded() && !detail) closeSettingsSubpage();
  });

  // Permissions are shown once, when the plugin is enabled with some it has not been granted; revoking one and
  // enabling again asks again for exactly that one.
  // Returns false when the plugin waits on the sheet, so its switch goes back to what the host says.
  function toggle(plugin: PluginRow, enabled: boolean): boolean {
    if (enabled && ungrantedCapabilities(plugin).length) {
      grantingId = plugin.id;
      return false;
    }
    setPluginEnabled(plugin.id, enabled);
    return true;
  }

  function confirmGrant(): void {
    if (grantingId) setPluginEnabled(grantingId, true);
    grantingId = null;
  }

  const label = (capability: string): string => {
    const key = capabilityLabelKey(capability);
    return key ? t(key) : capability;
  };
</script>

{#if detail}
  <PluginDetail plugin={detail} onenable={(enabled) => toggle(detail, enabled)} />
{:else if arePluginsLoaded()}
  <UiInsetList title={t("plugins.installed")}>
    {#each plugins as plugin (plugin.id)}
      <PluginListRow
        {plugin}
        onopen={() => openSettingsSubpage("plugins", `plugin:${plugin.id}`)}
        onenable={(enabled) => toggle(plugin, enabled)}
      />
    {:else}
      <p class="empty">{t("plugins.empty")}</p>
    {/each}
  </UiInsetList>
{/if}

{#if granting}
  <UiModal zone="plugin-grants" title={t("plugins.grantTitle", { name: granting.title })} oncancel={() => (grantingId = null)} ondefault={confirmGrant}>
    <p class="grant-message">{t("plugins.grantMessage", { name: granting.title })}</p>
    <ul class="grant-list">
      {#each grantList as capability (capability)}
        <li>{label(capability)}</li>
      {/each}
    </ul>
    {#snippet actions()}
      <UiButton onclick={() => (grantingId = null)}>{t("common.cancel")}</UiButton>
      <UiButton variant="primary" onclick={confirmGrant}>{t("plugins.grantEnable")}</UiButton>
    {/snippet}
  </UiModal>
{/if}

<style>
  .empty {
    margin: 0;
    padding: 32px 16px;
    color: var(--text-muted);
    font-size: var(--font-size-md);
    text-align: center;
  }

  .grant-message {
    margin: 0 0 var(--space-8);
    color: var(--text-secondary);
  }

  .grant-list {
    margin: 0;
    padding-left: 20px;
    color: var(--text-primary);
  }
</style>
