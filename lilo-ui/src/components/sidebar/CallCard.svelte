<!-- A call in any tab, shown or not: jump to it, toggle its microphone, camera and sound, leave it, and steer the
     tab it shares. Above the media card. -->
<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import { mediaActions, tabActions, tabShareActions, terminalActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { getCallCardTab } from "../../stores/media.svelte";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { getActiveTab, tabDisplayTitle } from "../../stores/tabs.svelte";

  const call = $derived(getCallCardTab());
  // During a call, the Mute Tab shortcut toggles the call's microphone.
  const muteKeys = $derived(shortcutKeys("tab.mute"));
  const soundLabel = $derived(t(call?.muted ? "tabItem.unmute" : "tabItem.mute"));
  const activeTab = $derived(getActiveTab());
  // The shown page can take over the share, unless it is the call itself, what is already shared, or a terminal.
  const canShareShown = $derived(
    !!call?.share && !!activeTab?.url && activeTab.kind !== "terminal" && activeTab.id !== call.id && activeTab.id !== call.share.tabId,
  );
</script>

{#if call}
  <div class="call-card">
  <div class="call-row">
    <!-- revealTerminal reveals any tab, switching Space when it is elsewhere. -->
    <button class="call-tab" use:tooltip={t("mediaCard.show")} onclick={() => terminalActions.reveal(call.id)}>
      <SiteFavicon src={call.faviconDataURL} title={call.title} />
      <span class="call-title">{call.title}</span>
    </button>
    <div class="call-controls">
      {#if call.hasMicrophone}
        {@const label = t(call.microphoneMuted ? "tabItem.unmuteMicrophone" : "tabItem.muteMicrophone")}
        <button
          class="call-btn"
          class:off={call.microphoneMuted}
          aria-label={label}
          aria-pressed={call.microphoneMuted}
          use:tooltip={muteKeys ? `${label} (${muteKeys})` : label}
          onclick={() => mediaActions.controlCall(call.id, "togglemicrophone")}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path d="M4 2.8C4 1.8 4.8 1 5.8 1H6.2C7.2 1 8 1.8 8 2.8V5.2C8 6.2 7.2 7 6.2 7H5.8C4.8 7 4 6.2 4 5.2V2.8Z" fill="currentColor" />
            <path d="M2.6 5.2C2.6 7 4.1 8.4 6 8.4C7.9 8.4 9.4 7 9.4 5.2" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
            <path d="M6 8.4V10.2M4.6 10.2H7.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
            {#if call.microphoneMuted}
              <path d="M2 2L10 10" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
            {/if}
          </svg>
        </button>
      {/if}
      {#if call.hasCamera}
        {@const label = t(call.cameraOff ? "mediaCard.turnOnCamera" : "mediaCard.turnOffCamera")}
        <button
          class="call-btn"
          class:off={call.cameraOff}
          aria-label={label}
          aria-pressed={call.cameraOff}
          use:tooltip={label}
          onclick={() => mediaActions.controlCall(call.id, "togglecamera")}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <rect x="1.4" y="3.4" width="6" height="5.2" rx="1.1" stroke="currentColor" stroke-width="1.2" />
            <path d="M7.8 5.2 10.6 3.9v4.2L7.8 6.8z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" />
            {#if call.cameraOff}
              <path d="M2 2L10 10" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
            {/if}
          </svg>
        </button>
      {/if}
      <button
        class="call-btn"
        aria-label={soundLabel}
        aria-pressed={call.muted}
        use:tooltip={soundLabel}
        onclick={() => tabActions.setMuted(call.id, !call.muted)}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          {#if call.muted}
            <path d="M2 4.5H3.5L6.5 2V10L3.5 7.5H2V4.5Z" fill="currentColor" opacity="0.5" />
            <path d="M8.5 4.5L10.5 6.5M10.5 4.5L8.5 6.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
          {:else}
            <path d="M2 4.5H3.5L6.5 2V10L3.5 7.5H2V4.5Z" fill="currentColor" />
            <path d="M8 4.5C8.83 5 8.83 7 8 7.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
            <path d="M9.5 3.5C11 4.5 11 7.5 9.5 8.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
          {/if}
        </svg>
      </button>
      {#if call.canHangUp}
        <button
          class="call-btn hang-up"
          aria-label={t("mediaCard.leaveCall")}
          use:tooltip={t("mediaCard.leaveCall")}
          onclick={() => mediaActions.controlCall(call.id, "hangup")}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            <path d="M6 4.3c-2 0-3.8.7-4.7 1.7-.3.3-.3.8 0 1.1l.8.8c.2.2.6.3.9.1l1.2-.6c.2-.1.4-.4.4-.7v-.9c.5-.2.9-.2 1.4-.2s1 0 1.4.2v.9c0 .3.2.6.4.7l1.2.6c.3.2.7.1.9-.1l.8-.8c.3-.3.3-.8 0-1.1C9.8 5 8 4.3 6 4.3Z" />
          </svg>
        </button>
      {/if}
    </div>
  </div>
  {#if call.share}
    {@const share = call.share}
    <div class="call-row share-row">
      <button class="call-tab share-tab" use:tooltip={t("mediaCard.show")} onclick={() => terminalActions.reveal(share.tabId)}>
        <span class="live-dot" aria-hidden="true"></span>
        <span class="call-title">{t("mediaCard.sharing", { title: tabDisplayTitle(share.title) })}</span>
      </button>
      {#if canShareShown && activeTab}
        {@const shown = activeTab}
        <button class="share-instead" onclick={() => tabShareActions.shareInstead(share.token, shown.id)}>
          {t("mediaCard.shareThisTab")}
        </button>
      {/if}
      <button
        class="call-btn"
        aria-label={t("mediaCard.stopSharing")}
        use:tooltip={t("mediaCard.stopSharing")}
        onclick={() => tabShareActions.stop(share.token)}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
          <rect x="2.5" y="2.5" width="7" height="7" rx="1.4" />
        </svg>
      </button>
    </div>
  {/if}
  </div>
{/if}

<style>
  .call-card {
    display: flex;
    flex-direction: column;
    gap: 2px;
    flex-shrink: 0;
    margin: 0 var(--sidebar-right-pad, 10px) 6px 10px;
    padding: 4px;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-10);
  }

  .call-row {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  .share-row {
    padding-top: 2px;
    border-top: 1px solid var(--separator);
  }

  .share-tab {
    color: var(--text-secondary);
  }

  /* The share is live: the others see this tab right now. */
  .live-dot {
    flex-shrink: 0;
    width: 7px;
    height: 7px;
    margin: 0 4px;
    border-radius: 50%;
    background: var(--danger);
  }

  .share-instead {
    flex-shrink: 0;
    height: 22px;
    padding: 0 8px;
    border: none;
    border-radius: var(--radius-sm);
    background: var(--accent);
    color: var(--accent-text);
    font-family: inherit;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-medium);
    cursor: pointer;
  }

  .share-instead:hover {
    background: var(--accent-hover);
  }

  .share-instead:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .call-tab {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 0;
    height: 26px;
    padding: 0 6px;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
    cursor: pointer;
  }

  .call-title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .call-controls {
    display: flex;
    flex-shrink: 0;
    gap: 1px;
  }

  .call-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .call-tab:hover,
  .call-btn:hover {
    background: var(--text-primary-tint-12);
  }

  /* An off microphone or camera reads at a glance: the others are not hearing or seeing you. */
  .call-btn.off,
  .call-btn.off:hover {
    background: var(--danger);
    color: var(--on-color);
  }

  .call-btn.hang-up {
    color: var(--danger);
  }

  .call-btn.hang-up:hover {
    background: var(--danger);
    color: var(--on-color);
  }

  .call-tab:focus-visible,
  .call-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }
</style>
