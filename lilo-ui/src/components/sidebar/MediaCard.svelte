<!-- Now playing in another tab: jump to it, play or pause, skip, mute. Fixed above the bottom bar. -->
<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import { mediaActions, tabActions, terminalActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { getMediaCardTab } from "../../stores/media.svelte";

  const tab = $derived(getMediaCardTab());
</script>

{#if tab}
  <div class="media-card">
    <!-- revealTerminal reveals any tab, switching Space when it is elsewhere. -->
    <button class="media-tab" use:tooltip={t("mediaCard.show")} onclick={() => terminalActions.reveal(tab.id)}>
      <SiteFavicon src={tab.faviconDataURL} title={tab.title} />
      <span class="media-title">{tab.title}</span>
    </button>
    <div class="media-controls">
      {#if tab.hasTrackControls}
        <button
          class="media-btn"
          aria-label={t("mediaCard.previous")}
          use:tooltip={t("mediaCard.previous")}
          onclick={() => mediaActions.control(tab.id, "previoustrack")}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            <path d="M3 2.5h1.3v7H3zM10 2.8v6.4a.4.4 0 0 1-.6.3L5 6.3a.4.4 0 0 1 0-.6l4.4-3.2a.4.4 0 0 1 .6.3Z" />
          </svg>
        </button>
      {/if}
      <button
        class="media-btn"
        aria-label={t(tab.playing ? "mediaCard.pause" : "mediaCard.play")}
        use:tooltip={t(tab.playing ? "mediaCard.pause" : "mediaCard.play")}
        onclick={() => mediaActions.control(tab.id, tab.playing ? "pause" : "play")}
      >
        {#if tab.playing}
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            <rect x="2.75" y="2" width="2.3" height="8" rx="0.6" />
            <rect x="6.95" y="2" width="2.3" height="8" rx="0.6" />
          </svg>
        {:else}
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            <path d="M3.5 2.4v7.2a.5.5 0 0 0 .76.43l5.9-3.6a.5.5 0 0 0 0-.86l-5.9-3.6a.5.5 0 0 0-.76.43Z" />
          </svg>
        {/if}
      </button>
      {#if tab.hasTrackControls}
        <button
          class="media-btn"
          aria-label={t("mediaCard.next")}
          use:tooltip={t("mediaCard.next")}
          onclick={() => mediaActions.control(tab.id, "nexttrack")}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            <path d="M7.7 2.5H9v7H7.7zM2 2.8v6.4a.4.4 0 0 0 .6.3L7 6.3a.4.4 0 0 0 0-.6L2.6 2.5a.4.4 0 0 0-.6.3Z" />
          </svg>
        </button>
      {/if}
      <button
        class="media-btn"
        class:muted={tab.muted}
        aria-label={t(tab.muted ? "tabItem.unmute" : "tabItem.mute")}
        use:tooltip={t(tab.muted ? "tabItem.unmute" : "tabItem.mute")}
        onclick={() => tabActions.setMuted(tab.id, !tab.muted)}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          {#if tab.muted}
            <path d="M2 4.5H3.5L6.5 2V10L3.5 7.5H2V4.5Z" fill="currentColor" opacity="0.5" />
            <path d="M8.5 4.5L10.5 6.5M10.5 4.5L8.5 6.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
          {:else}
            <path d="M2 4.5H3.5L6.5 2V10L3.5 7.5H2V4.5Z" fill="currentColor" />
            <path d="M8 4.5C8.83 5 8.83 7 8 7.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
            <path d="M9.5 3.5C11 4.5 11 7.5 9.5 8.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
          {/if}
        </svg>
      </button>
    </div>
  </div>
{/if}

<style>
  .media-card {
    display: flex;
    align-items: center;
    gap: 2px;
    flex-shrink: 0;
    margin: 0 var(--sidebar-right-pad, 10px) 6px 10px;
    padding: 4px;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-10);
  }

  .media-tab {
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

  .media-title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .media-controls {
    display: flex;
    flex-shrink: 0;
    gap: 1px;
  }

  .media-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
  }

  .media-btn.muted {
    color: var(--text-primary);
  }

  .media-tab:hover,
  .media-btn:hover {
    background: var(--text-primary-tint-12);
    color: var(--text-primary);
  }

  .media-tab:focus-visible,
  .media-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }
</style>
