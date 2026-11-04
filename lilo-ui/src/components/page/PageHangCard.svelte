<!-- The active tab's page stopped responding: a modal over that page alone, which goes by itself once the
     page answers again. Native blurs the frozen page underneath. -->
<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiModal from "../ui/UiModal.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { announce } from "../../lib/announce";
  import {
    closeHungTab,
    getHangSeconds,
    getShownPageHang,
    reloadHungPage,
    waitForHungPage,
  } from "../../stores/pageHang.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { getActiveTab, getActiveTabId } from "../../stores/tabs.svelte";
  import { isBlockerAllowlisted } from "../../stores/urlBarDrawer.svelte";

  const tabId = $derived(getActiveTabId());
  const hang = $derived(getShownPageHang(tabId));
  const host = $derived(hang?.host || t("pageHang.thisPage"));
  const title = $derived(hang ? t(hang.repeat ? "pageHang.repeatTitle" : "pageHang.title", { host }) : "");
  const tab = $derived(getActiveTab());
  const seconds = $derived(getHangSeconds(tabId) ?? 0);

  // Spoken once as the card shows: a live region over the card would re-read its seconds counter every tick.
  $effect(() => {
    if (title) announce(title);
  });

  // Turning the blocker off for the site only helps while it still blocks there.
  const offerBlockerOff = $derived(
    !!hang?.repeat && !!hang.host && getSetting("contentBlockerEnabled", "true") === "true" && !isBlockerAllowlisted(hang.host),
  );

  // A counter only from 5 s: under that it would read as a glitch.
  const message = $derived(
    hang?.repeat
      ? t(offerBlockerOff ? "pageHang.repeatMessage" : "pageHang.repeatMessagePlain")
      : seconds >= 5 ? t("pageHang.stuckFor", { seconds: String(seconds) }) : t("pageHang.message"),
  );
</script>

{#if hang}
  <!-- Not window-modal: the other tabs stay a click away while this one is stuck. -->
  <UiModal
    zone="page-hang-card"
    width={380}
    windowModal={false}
    oncancel={() => waitForHungPage(tabId)}
    ondefault={() => reloadHungPage(tabId, offerBlockerOff)}
  >
    {#snippet header(titleId)}
      <div class="hang-head">
        {#if tab}<SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={32} radius={8} />{/if}
        <div>
          <h2 class="title" id={titleId}>{title}</h2>
          <p class="message">{message}</p>
        </div>
      </div>
    {/snippet}
    {#snippet leading()}
      {#if hang.repeat}
        <button class="report" type="button" onclick={() => tabActions.reportUnresponsivePage()}>{t("pageHang.report")}</button>
      {:else}
        <UiButton variant="danger" onclick={() => closeHungTab(tabId)}>{t("pageHang.closeTab")}</UiButton>
      {/if}
    {/snippet}
    {#snippet actions()}
      <UiButton onclick={() => waitForHungPage(tabId)}>{t("pageHang.wait")}</UiButton>
      {#if offerBlockerOff}
        <UiButton onclick={() => reloadHungPage(tabId)}>{t("pageHang.reload")}</UiButton>
        <UiButton variant="primary" onclick={() => reloadHungPage(tabId, true)}>{t("pageHang.reloadWithoutBlocker")}</UiButton>
      {:else}
        <UiButton variant="primary" onclick={() => reloadHungPage(tabId)}>{t("pageHang.reload")}</UiButton>
      {/if}
    {/snippet}
  </UiModal>
{/if}

<style>
  .hang-head {
    display: flex;
    align-items: flex-start;
    gap: var(--space-12);
  }

  .title {
    margin: 0;
    font-size: var(--font-size-modal);
    font-weight: var(--font-weight-semibold);
    line-height: 1.3;
    overflow-wrap: anywhere;
  }

  .message {
    margin: var(--space-4) 0 0;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .report {
    border: none;
    background: none;
    padding: 0;
    font: inherit;
    /* Not the accent: as text on the card it cannot read on every Space color. */
    color: var(--text-secondary);
    text-decoration: underline;
    cursor: pointer;
  }

  .report:hover {
    color: var(--text-primary);
  }

  .report:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }
</style>
