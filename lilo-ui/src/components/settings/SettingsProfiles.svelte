<script lang="ts">
  import { profileActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { getAgentsProfileId, getAgentsSpaceId } from "../../stores/agents.svelte";
  import { getProfileExtensionCounts, getProfiles } from "../../stores/profiles.svelte";
  import { getSpaces } from "../../stores/spaces.svelte";
  import { nextProfileColor, PASTEL_COLORS, spacesByProfile, userProfiles } from "./profilesModel";
  import SettingsProfileRow from "./SettingsProfileRow.svelte";
  import UiButton from "../ui/UiButton.svelte";

  const users = $derived(userProfiles(getProfiles(), getAgentsProfileId()));
  const usage = $derived(spacesByProfile(getSpaces(), getAgentsSpaceId()));
  const counts = $derived(getProfileExtensionCounts());

  let creating = $state(false);
  let newName = $state("");
  let newColor = $state("");

  $effect(() => {
    profileActions.loadStats();
  });

  function startCreate(): void {
    newName = "";
    newColor = nextProfileColor(getProfiles());
    creating = true;
  }

  function create(): void {
    const name = newName.trim();
    if (!name) return;
    profileActions.create(name, newColor);
    creating = false;
  }
</script>

<div class="profiles-section">
  <div class="profile-grid" data-setting-id="newProfile">
    {#each users as profile (profile.id)}
      <SettingsProfileRow {profile} {users} {usage} extensionCount={counts ? (counts[profile.id] ?? 0) : undefined} />
    {/each}

    {#if creating}
      <div class="new-card">
        <input
          class="new-name"
          type="text"
          {@attach (node) => node.focus()}
          bind:value={newName}
          placeholder={t("settings.profiles.namePlaceholder")}
          aria-label={t("settings.profiles.namePlaceholder")}
          spellcheck="false"
          onkeydown={(event) => {
            if (event.key === "Enter") create();
            if (event.key !== "Escape") return;
            // Handled here so the settings surface, which also closes on Escape, keeps open.
            event.preventDefault();
            creating = false;
          }}
        />
        <div class="new-colors">
          {#each PASTEL_COLORS as color, index (color)}
            <button
              class="new-swatch"
              class:selected={newColor === color}
              style:background={color}
              aria-label={t("common.colorSwatch", { number: String(index + 1) })}
              aria-pressed={newColor === color}
              onclick={() => (newColor = color)}
            ></button>
          {/each}
        </div>
        <div class="new-actions">
          <UiButton variant="ghost" onclick={() => (creating = false)}>{t("common.cancel")}</UiButton>
          <UiButton variant="primary" disabled={!newName.trim()} onclick={create}>{t("settings.profiles.create")}</UiButton>
        </div>
      </div>
    {:else}
      <button class="add-card" onclick={startCreate}>
        <span class="add-title">+ {t("settings.profiles.newProfile")}</span>
        <span class="add-detail">{t("settings.profiles.newProfileDetail")}</span>
      </button>
    {/if}
  </div>

  <!-- The agents' throwaway profile is not one of the user's: one line says what it is. -->
  {#if getAgentsProfileId()}
    <div class="agents-row">
      <span class="agents-avatar" aria-hidden="true">
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <rect x="2.5" y="5" width="11" height="8" rx="2.5" />
          <path d="M8 5V2.5M6.5 2.5h3M1 8.5v2M15 8.5v2" />
          <circle cx="5.75" cy="9" r="0.6" fill="currentColor" />
          <circle cx="10.25" cy="9" r="0.6" fill="currentColor" />
        </svg>
      </span>
      <span><b>{t("settings.profiles.agentsTitle")}</b> {t("settings.profiles.agentsDetail")}</span>
    </div>
  {/if}
</div>

<style>
  .profile-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 10px;
    padding: 6px 0;
  }

  .add-card,
  .new-card {
    display: grid;
    gap: 10px;
    padding: 14px;
    border: 1px dashed color-mix(in srgb, var(--text-primary) 18%, transparent);
    border-radius: var(--radius-lg);
    background: transparent;
    color: var(--text-secondary);
    font-family: inherit;
  }

  .add-card {
    min-height: 120px;
    place-content: center;
    text-align: center;
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .add-card:hover {
    background: var(--bg-hover);
  }

  .add-card:focus-visible {
    outline: var(--focus-outline);
  }

  .add-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .add-detail {
    font-size: var(--font-size-sm);
  }

  .new-name {
    height: var(--control-height-lg);
    padding: var(--space-6) var(--space-10);
    border: 1px solid var(--text-primary-tint-12);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--bg-primary) 92%, transparent);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
  }

  .new-name:focus {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .new-colors {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .new-swatch {
    width: 20px;
    height: 20px;
    padding: 0;
    border: 1px solid var(--text-primary-tint-12);
    border-radius: 50%;
    cursor: pointer;
  }

  .new-swatch.selected {
    box-shadow: 0 0 0 2px var(--bg-primary), 0 0 0 3.5px var(--text-primary);
  }

  .new-swatch:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .new-actions {
    display: flex;
    justify-content: flex-end;
    gap: 6px;
  }

  .agents-row {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-top: 4px;
    padding: 10px 12px;
    border-radius: var(--radius-md);
    background: var(--bg-hover);
    color: var(--text-secondary);
    font-size: var(--font-size-md);
    line-height: 1.4;
  }

  .agents-row b {
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  .agents-avatar {
    flex: none;
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border-radius: var(--radius-sm);
    background: var(--agents);
    color: var(--on-color);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-bold);
  }
</style>
