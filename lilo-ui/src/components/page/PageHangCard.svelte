<!-- The active tab's page stopped responding: a card over it, which goes by itself once the page
     answers again. Native blurs the frozen page underneath. -->
<script lang="ts">
  import UiButton from "../ui/UiButton.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
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
  import { getActiveTabId } from "../../stores/tabs.svelte";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import { isBlockerAllowlisted } from "../../stores/urlBarDrawer.svelte";

  const tabId = $derived(getActiveTabId());
  const hang = $derived(getShownPageHang(tabId));
  const host = $derived(hang?.host || t("pageHang.thisPage"));
  const title = $derived(hang ? t(hang.repeat ? "pageHang.repeatTitle" : "pageHang.title", { host }) : "");
  const titleId = $props.id();

  // Spoken once as the card shows: a live region over the card would re-read its seconds counter every tick.
  $effect(() => {
    if (title) announce(title);
  });

  // Turning the blocker off for the site only helps while it still blocks there.
  const offerBlockerOff = $derived(
    !!hang?.repeat && !!hang.host && getSetting("contentBlockerEnabled", "true") === "true" && !isBlockerAllowlisted(hang.host),
  );
</script>

{#if hang}
  <div
    class="page-hang chrome-content-overlay-root"
    class:sidebar-hidden={!isSidebarVisible()}
  >
    <div class="card float-surface" role="group" aria-labelledby={titleId} use:reportInteractiveZone={{ id: "page-hang-card" }}>
      <span class="badge" aria-hidden="true">
        {#if hang.repeat}
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M12 9v4M12 17h.01"/>
            <path d="M10.3 3.9 2.4 18a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>
          </svg>
        {:else}
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M7 3h10M7 21h10M8 3v4l4 5-4 5v4M16 3v4l-4 5 4 5v4"/>
          </svg>
        {/if}
      </span>
      {#if hang.repeat}
        <h1 class="title" id={titleId}>{title}</h1>
        <p class="message">{offerBlockerOff ? t("pageHang.repeatMessage") : t("pageHang.repeatMessagePlain")}</p>
        <div class="actions">
          {#if offerBlockerOff}
            <UiButton variant="primary" onclick={() => reloadHungPage(tabId, true)}>{t("pageHang.reloadWithoutBlocker")}</UiButton>
          {/if}
          <UiButton variant={offerBlockerOff ? "secondary" : "primary"} onclick={() => reloadHungPage(tabId)}>{t("pageHang.reload")}</UiButton>
        </div>
        <button class="report" type="button" onclick={() => tabActions.reportUnresponsivePage()}>{t("pageHang.report")}</button>
      {:else}
        <h1 class="title" id={titleId}>{title}</h1>
        <p class="message">{t("pageHang.stuckFor", { seconds: String(getHangSeconds(tabId) ?? 0) })}</p>
        <div class="actions">
          <UiButton variant="primary" onclick={() => reloadHungPage(tabId)}>{t("pageHang.reload")}</UiButton>
          <UiButton onclick={() => waitForHungPage(tabId)}>{t("pageHang.wait")}</UiButton>
          <UiButton onclick={() => closeHungTab(tabId)}>{t("pageHang.closeTab")}</UiButton>
        </div>
      {/if}
    </div>
  </div>
{/if}

<style>
  /* Only the card takes clicks: the blurred page around it stays the page's. */
  .page-hang {
    display: flex;
    align-items: center;
    justify-content: center;
    pointer-events: none;
  }

  .card {
    pointer-events: auto;
    width: min(360px, calc(100% - 32px));
    box-sizing: border-box;
    display: grid;
    justify-items: center;
    gap: 10px;
    padding: 22px;
    border-radius: var(--radius-lg);
    text-align: center;
  }

  .badge {
    width: 44px;
    height: 44px;
    border-radius: 50%;
    display: grid;
    place-items: center;
    color: color-mix(in srgb, var(--attention) 70%, var(--text-primary));
    background: color-mix(in srgb, var(--attention) 18%, transparent);
  }

  .title {
    margin: 0;
    font-size: var(--font-size-xl);
    font-weight: var(--font-weight-semibold);
    overflow-wrap: anywhere;
  }

  .message {
    margin: 0;
    font-size: var(--font-size-md);
    line-height: 1.5;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .actions {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 8px;
    margin-top: 4px;
  }

  .report {
    border: none;
    background: none;
    padding: 0;
    font: inherit;
    font-size: var(--font-size-sm);
    /* Not the accent: as text on the card it cannot read on every Space color. */
    color: var(--text-secondary);
    text-decoration: underline;
    cursor: pointer;
  }

  .report:hover {
    color: var(--text-primary);
  }
</style>
