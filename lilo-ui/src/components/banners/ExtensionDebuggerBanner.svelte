<!-- Chrome's infobar while an extension debugs a tab: closing it, like Cancel, detaches the extension. -->
<script lang="ts">
  import UiBanner from "../ui/UiBanner.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import { extensionActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { getExtensionDebuggers } from "../../stores/banners.svelte";
</script>

{#each getExtensionDebuggers() as { id, name } (id)}
  <UiBanner zoneId={`extension-debugger-${id}`} closeLabel={t("extensionDebugger.cancel")} onclose={() => extensionActions.cancelDebugging(id)}>
    <span>{t("extensionDebugger.message", { name })}</span>
    {#snippet actions()}
      <UiButton onclick={() => extensionActions.cancelDebugging(id)}>{t("extensionDebugger.cancel")}</UiButton>
    {/snippet}
  </UiBanner>
{/each}
