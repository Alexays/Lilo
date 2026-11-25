<script lang="ts">
  import "../../lib/i18n/pluginCatalog";
  import UiToggle from "../../components/ui/UiToggle.svelte";
  import { t } from "../i18n/state.svelte";
  import { isPluginPending } from "../../stores/plugins.svelte";
  import type { PluginRow } from "./pluginModel";

  interface Props {
    plugin: PluginRow;
    /** Returns false when the plugin cannot start yet (it waits on its permissions): the switch goes back. */
    onenable: (enabled: boolean) => boolean;
  }

  let { plugin, onenable }: Props = $props();

  // What the switch shows is the host's word: it follows the user's tap while the host answers, and goes back
  // to the host's state when the wait ends or the tap was not accepted.
  let shown = $state(false);
  $effect.pre(() => {
    if (!isPluginPending(plugin.id)) shown = plugin.enabled;
  });
</script>

<UiToggle
  bind:checked={shown}
  disabled={Boolean(plugin.rejectionReason) || isPluginPending(plugin.id)}
  ariaLabel={t("plugins.enabledToggleLabel", { name: plugin.title })}
  onchange={(checked) => {
    if (!onenable(checked)) shown = plugin.enabled;
  }}
/>
