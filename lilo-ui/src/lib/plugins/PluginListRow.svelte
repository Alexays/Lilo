<script lang="ts">
  import UiBadge from "../../components/ui/UiBadge.svelte";
  import { getFormatLocale, t } from "../i18n/state.svelte";
  import { capabilityLabelKey, pluginInitial, type PluginRow } from "./pluginModel";
  import PluginSwitch from "./PluginSwitch.svelte";

  interface Props {
    plugin: PluginRow;
    onopen: () => void;
    onenable: (enabled: boolean) => boolean;
  }

  let { plugin, onopen, onenable }: Props = $props();

  const rejected = $derived(Boolean(plugin.rejectionReason));
  const capabilities = $derived(
    new Intl.ListFormat(getFormatLocale(), { type: "unit", style: "short" }).format(
      plugin.capabilities.map((capability) => {
        const key = capabilityLabelKey(capability);
        return key ? t(key) : capability;
      }),
    ),
  );
  const metaLine = $derived(
    rejected ? (plugin.rejectionReason ?? "") : [plugin.version && `v${plugin.version}`, capabilities].filter(Boolean).join(" · "),
  );
</script>

<div class="plugin-row" class:disabled={!plugin.enabled && !rejected}>
  <button class="row-main" type="button" onclick={onopen} aria-label={t("plugins.openDetailsLabel", { name: plugin.title })}>
    <span class="row-icon" aria-hidden="true">
      {#if plugin.icon}<img class="row-icon-image" src={plugin.icon} alt="" draggable="false" />{:else}{pluginInitial(plugin)}{/if}
    </span>
    <span class="row-copy">
      <span class="row-name">{plugin.title}</span>
      <span class="row-meta" class:rejected title={metaLine}>{metaLine}</span>
    </span>
  </button>

  {#if plugin.running}<UiBadge tone="success">{t("plugins.running")}</UiBadge>{/if}

  <PluginSwitch {plugin} {onenable} />
</div>

<style>
  .plugin-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: 11px 14px;
    min-width: 0;
  }

  .row-main {
    flex: 1;
    display: flex;
    align-items: center;
    gap: 14px;
    min-width: 0;
    padding: 0;
    background: none;
    border: none;
    text-align: left;
    cursor: pointer;
    color: inherit;
    font: inherit;
  }

  .row-main:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .plugin-row.disabled .row-main {
    opacity: var(--disabled-opacity);
  }

  .row-icon {
    position: relative;
    flex-shrink: 0;
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

  .row-icon-image {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
  }

  .row-copy {
    display: grid;
    gap: 2px;
    min-width: 0;
  }

  .row-name {
    overflow: hidden;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .row-meta {
    overflow: hidden;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .row-meta.rejected {
    color: var(--danger-text);
  }
</style>
