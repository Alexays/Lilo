<script lang="ts">
  import { onMount } from "svelte";
  import { getCrashRecoverySeq, getDegradedSpaceName } from "../../stores/banners.svelte";
  import { getOnboarding } from "../../stores/onboarding.svelte";
  import { getTabShareRequest } from "../../stores/tabShare.svelte";
  import { getActiveUrlBarDrawer } from "../../stores/urlBarDrawer.svelte";
  import { closeWhatsNew, getWhatsNewRequest, initWhatsNewStore, requestAutomaticWhatsNew } from "../../stores/whatsNew.svelte";

  const request = $derived(getWhatsNewRequest());
  const drawer = $derived(getActiveUrlBarDrawer());
  const blocked = $derived(getOnboarding().visible || getCrashRecoverySeq() > 0 || getDegradedSpaceName() !== null
    || getTabShareRequest() !== null
    || (drawer !== null && drawer.kind !== "site" && drawer.kind !== "defaultBrowser"));
  const shown = $derived(request && !blocked ? request : null);
  let sheet = $state<Promise<typeof import("./WhatsNewSheet.svelte")> | null>(null);

  onMount(() => { initWhatsNewStore(); requestAutomaticWhatsNew(); });

  $effect(() => {
    if (!shown || sheet) return;
    sheet = import("./WhatsNewSheet.svelte");
    void sheet.catch(() => { closeWhatsNew(); sheet = null; });
  });
</script>

{#if shown && sheet}
  {#await sheet then loaded}
    <loaded.default request={shown} onclose={closeWhatsNew} />
  {:catch}
    <!-- A failed chunk leaves the native marker untouched, so a later launch can retry. -->
  {/await}
{/if}
