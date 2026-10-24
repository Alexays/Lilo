<script lang="ts">
  import { tick } from "svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { type SettingsSectionId, takeSettingsHighlight } from "../../stores/panels.svelte";
  import { getSettingsStatus } from "../../stores/settings.svelte";
  import SearchEngineEditor from "./SearchEngineEditor.svelte";
  import SettingsAdvanced from "./SettingsAdvanced.svelte";
  import SettingsExtensions from "./SettingsExtensions.svelte";
  import SettingsGroups from "./SettingsGroups.svelte";
  import SettingsSearchResults from "./SettingsSearchResults.svelte";
  import SettingsSites from "./SettingsSites.svelte";
  import SettingsBlockerSites from "./SettingsBlockerSites.svelte";
  import SettingsShortcuts from "./SettingsShortcuts.svelte";
  import SettingsTerminal from "./SettingsTerminal.svelte";

  interface Props {
    section: SettingsSectionId;
    subpage: string | null;
    query: string;
  }

  let { section, subpage, query }: Props = $props();

  const status = $derived(getSettingsStatus());

  // The length of the setting-flash animation below; a timer, not animationend, clears it,
  // since reduced motion replaces the animation with a static outline.
  const SETTING_FLASH_MS = 1600;

  let container: HTMLDivElement | undefined = $state();

  // A search result led here: bring its row into view and flash it once the page has rendered.
  $effect(() => {
    void section;
    const setting = takeSettingsHighlight();
    if (!setting) return;
    void tick().then(() => {
      const row = container?.querySelector<HTMLElement>(`[data-setting-id="${setting}"]`);
      if (!row) return;
      row.scrollIntoView({ block: "center", behavior: prefersReducedMotion() ? "auto" : "smooth" });
      row.classList.add("setting-flash");
      setTimeout(() => row.classList.remove("setting-flash"), SETTING_FLASH_MS);
    });
  });
</script>

<div class="settings-section-content" bind:this={container}>
  {#if status}
    <div class="status-banner" class:status-error={status.level === "error"} role="status">
      {status.message}
    </div>
  {/if}

  {#if query.trim()}
    <SettingsSearchResults {query} />
  {:else}
    {#key `${section}/${subpage ?? ""}`}
      <div class="settings-section-page">
        {#if subpage === "engines"}
          <SearchEngineEditor />
        {:else if subpage === "shortcuts"}
          <SettingsShortcuts />
        {:else if subpage === "blockerSites"}
          <SettingsBlockerSites />
        {:else if subpage === "sites" || subpage?.startsWith("site:")}
          <SettingsSites {subpage} />
        {:else if section === "terminal"}
          <SettingsTerminal />
        {:else if section === "extensions"}
          <SettingsExtensions {subpage} />
        {:else if section === "advanced"}
          <SettingsAdvanced />
        {:else}
          <SettingsGroups {section} />
        {/if}
      </div>
    {/key}
  {/if}
</div>

<style>
  .settings-section-content,
  .settings-section-page {
    display: grid;
    gap: 22px;
    max-width: 900px;
  }

  /* Opacity only: a transform here would trap the confirm sheets' positioning. */
  .settings-section-page {
    animation: settings-page-in 160ms var(--motion-ease-organic);
  }

  @keyframes settings-page-in {
    from {
      opacity: 0;
    }
  }

  .status-banner {
    padding: 8px 12px;
    border-radius: var(--radius-md);
    background: var(--bg-hover);
    color: var(--text-primary);
    font-size: var(--font-size-sm);
  }

  .status-error {
    background: color-mix(in srgb, var(--danger) 12%, transparent);
  }

  .settings-section-content :global(.setting-flash) {
    border-radius: var(--radius-md);
    animation: setting-flash 1.6s var(--motion-ease-organic);
  }

  @keyframes setting-flash {
    0%,
    40% {
      background: var(--accent-tint-14);
      box-shadow: 0 0 0 2px var(--accent-tint-22);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .settings-section-page {
      animation: none;
    }

    .settings-section-content :global(.setting-flash) {
      animation: none;
      outline: var(--focus-outline);
    }
  }
</style>
