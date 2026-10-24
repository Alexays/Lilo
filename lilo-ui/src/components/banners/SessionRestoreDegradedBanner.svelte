<script lang="ts">
  import UiBanner from "../ui/UiBanner.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    dismissSessionRestoreDegradedBanner,
    getDegradedSpaceName,
  } from "../../stores/banners.svelte";

  // Stays visible until dismissed: unlike the crash banner, this reports degraded data.
  const spaceName = $derived(getDegradedSpaceName());
</script>

{#if spaceName !== null}
  <UiBanner zoneId="session-restore-degraded-banner" closeLabel={t("common.close")} onclose={dismissSessionRestoreDegradedBanner}>
    <span>{t("sessionRestore.degraded", { name: spaceName })}</span>
  </UiBanner>
{/if}
