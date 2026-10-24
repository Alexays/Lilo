<script lang="ts">
  import UiBanner from "../ui/UiBanner.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    dismissCrashRecoveryBanner,
    getCrashRecoverySeq,
  } from "../../stores/banners.svelte";

  const seq = $derived(getCrashRecoverySeq());

  // Keyed on the sequence so a repeat event restarts the auto-hide instead of cutting it short.
  $effect(() => {
    if (seq === 0) return;
    const timer = setTimeout(dismissCrashRecoveryBanner, 5000);
    return () => clearTimeout(timer);
  });
</script>

{#if seq > 0}
  <UiBanner zoneId="crash-recovery-banner" closeLabel={t("common.close")} onclose={dismissCrashRecoveryBanner}>
    <span>{t("crashRecovery.sessionRestored")}</span>
  </UiBanner>
{/if}
