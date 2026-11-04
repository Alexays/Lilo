<script lang="ts">
  import { featureFlagsActions } from "../../lib/bridge/actions";
  import type { BridgeFeatureFlagSnapshot } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import UiBadge from "../ui/UiBadge.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiToggle from "../ui/UiToggle.svelte";

  let { flag }: { flag: BridgeFeatureFlagSnapshot } = $props();
</script>

<!-- The key says which flag it is; the details, when WebKit has some, show on hover. -->
<div title={flag.details || undefined}>
  <UiListRow title={flag.name || flag.key} description={flag.name ? flag.key : flag.details || undefined}>
    {#snippet action()}
      {#if flag.modified}<UiBadge tone="accent">{t("featureFlags.modifiedBadge")}</UiBadge>{/if}
      <UiToggle
        checked={flag.enabled}
        ariaLabel={flag.name}
        onchange={(enabled) => featureFlagsActions.setFlag(flag.key, enabled)}
      />
    {/snippet}
  </UiListRow>
</div>
