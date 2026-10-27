<script lang="ts">
  import { dismissable } from "../../lib/actions/dismissable";
  import type { BridgeProfileSnapshot } from "../../lib/bridge/protocol";
  import { profileActions, spaceActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { showProfileExtensions } from "../../stores/extensions.svelte";
  import { closeSettingsShell, openSettings, openSettingsSubpage } from "../../stores/panels.svelte";
  import { getActiveProfileId } from "../../stores/profiles.svelte";
  import type { SpaceState } from "../../stores/spaces.svelte";
  import BottomConfirmSheet from "../ui/BottomConfirmSheet.svelte";
  import { PASTEL_COLORS, profileRemoval } from "./profilesModel";
  import UiSelect from "../ui/UiSelect.svelte";
  import UiTextField from "../ui/UiTextField.svelte";

  let {
    profile,
    users,
    usage,
    extensionCount,
  }: {
    profile: BridgeProfileSnapshot;
    users: BridgeProfileSnapshot[];
    usage: Map<string, SpaceState[]>;
    extensionCount: number | undefined;
  } = $props();

  let menuOpen = $state(false);
  let renaming = $state(false);
  let recoloring = $state(false);
  let confirmingRemove = $state(false);
  let moveTo = $state("");
  let moreButton: HTMLButtonElement;

  const spaces = $derived(usage.get(profile.id) ?? []);
  const removal = $derived(profileRemoval(profile, users, usage));
  const isActive = $derived(getActiveProfileId() === profile.id);

  function rename(value: string): void {
    renaming = false;
    const name = value.trim();
    if (name && name !== profile.name) profileActions.update({ id: profile.id, name });
  }

  function closeColors(): void {
    recoloring = false;
    moreButton.focus();
  }

  function recolor(color: string): void {
    closeColors();
    if (color !== profile.color) profileActions.update({ id: profile.id, color });
  }

  function pick(action: () => void): void {
    menuOpen = false;
    action();
  }

  function manageExtensions(): void {
    showProfileExtensions(profile.id);
    openSettings("extensions");
  }

  function startRemove(): void {
    const targets = removal.targets;
    moveTo = (targets.find((candidate) => candidate.isDefault) ?? targets[0])?.id ?? "";
    confirmingRemove = true;
  }

  function goToSpace(id: string): void {
    spaceActions.switchTo(id);
    closeSettingsShell();
  }
</script>

<article class="profile-card" style:--profile-color={profile.color}>
  <div class="card-top">
    {#if renaming}
      <!-- The field commits on change only: leaving it unchanged, by Enter, Escape or a click
           away, has to close it here. -->
      <span
        class="rename-field"
        role="presentation"
        {@attach (node) => node.querySelector("input")?.select()}
        onfocusout={() => (renaming = false)}
        onkeydown={(event) => {
          const input = event.target as HTMLInputElement;
          if (event.key === "Escape") {
            // Restored before the blur so the field reports no change.
            event.preventDefault();
            input.value = profile.name;
          }
          if (event.key === "Enter" || event.key === "Escape") input.blur();
        }}
      >
        <UiTextField value={profile.name} ariaLabel={t("settings.profiles.rename")} oncommit={rename} />
      </span>
    {:else}
      <span class="card-name">{profile.name}</span>
    {/if}
    <div class="menu-anchor" data-profile-menu={profile.id}>
      <button
        bind:this={moreButton}
        class="more-btn"
        aria-label={t("settings.profiles.actions", { name: profile.name })}
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        onclick={() => (menuOpen = !menuOpen)}
      >
        <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
          <circle cx="3.5" cy="8" r="1.3" /><circle cx="8" cy="8" r="1.3" /><circle cx="12.5" cy="8" r="1.3" />
        </svg>
      </button>
      {#if menuOpen}
        <div
          class="profile-menu float-surface float-popover"
          role="menu"
          tabindex="-1"
          {@attach dismissable({ onDismiss: () => (menuOpen = false), ignore: ".more-btn" })}
          {@attach (node) => node.querySelector("button")?.focus()}
          onkeydown={(event) => {
            // Handled here so the settings surface, which also closes on Escape, keeps open.
            if (event.key !== "Escape") return;
            event.preventDefault();
            menuOpen = false;
          }}
        >
          <button class="float-row" role="menuitem" onclick={() => pick(() => (renaming = true))}>
            {t("settings.profiles.rename")}
          </button>
          <button class="float-row" role="menuitem" onclick={() => pick(() => (recoloring ? closeColors() : (recoloring = true)))}>
            {t("settings.profiles.changeColor")}
          </button>
          <button class="float-row" role="menuitem" onclick={() => pick(manageExtensions)}>
            {t("settings.profiles.manageExtensions")}
          </button>
          <!-- The clear-data flow acts on the window's own profile only. -->
          {#if isActive}
            <button class="float-row" role="menuitem" onclick={() => pick(() => openSettingsSubpage("privacy", "browsingData"))}>
              {t("settings.profiles.clearData")}
            </button>
          {/if}
          <div class="menu-separator" role="separator"></div>
          <!-- Tooltip on a wrapper span: disabled buttons swallow the pointer events. -->
          <span use:tooltip={{ text: t("settings.profiles.lastProfile"), disabled: removal.removable }}>
            <button
              class="float-row danger"
              role="menuitem"
              disabled={!removal.removable}
              onclick={() => pick(startRemove)}
            >
              {t("settings.profiles.remove")}
            </button>
          </span>
        </div>
      {/if}
    </div>
  </div>

  {#if recoloring}
    <!-- Opens on the current color; Escape keeps it, handled here so Settings stays open. A press
         in the card's menu keeps it open, so Change color toggles it rather than reopening it. -->
    <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
    <div
      class="recolor-row"
      role="group"
      aria-label={t("settings.profiles.changeColor")}
      {@attach dismissable({ onDismiss: () => (recoloring = false), ignore: `[data-profile-menu="${profile.id}"]` })}
      {@attach (node) => (node.querySelector<HTMLElement>(".mini-swatch.selected") ?? node.querySelector<HTMLElement>(".mini-swatch"))?.focus()}
      onkeydown={(event) => {
        if (event.key !== "Escape") return;
        event.preventDefault();
        closeColors();
      }}
    >
      {#each PASTEL_COLORS as color, index (color)}
        <button
          class="mini-swatch"
          class:selected={profile.color === color}
          style:background={color}
          aria-label={t("common.colorSwatch", { number: String(index + 1) })}
          aria-pressed={profile.color === color}
          onclick={() => recolor(color)}
        ></button>
      {/each}
    </div>
  {/if}

  <div class="chips">
    {#each spaces as space (space.id)}
      <button class="chip" use:tooltip={t("settings.profiles.goToSpace", { name: space.name })} onclick={() => goToSpace(space.id)}>
        <span aria-hidden="true">{space.icon}</span><span class="chip-name">{space.name}</span>
      </button>
    {:else}
      <span class="chip none">{t("settings.profiles.noSpace")}</span>
    {/each}
  </div>

  {#if extensionCount !== undefined}
    <div class="stats">
      {extensionCount === 1
        ? t("settings.profiles.extensionCountOne")
        : t("settings.profiles.extensionCount", { count: extensionCount })}
    </div>
  {/if}
</article>

<BottomConfirmSheet
  visible={confirmingRemove}
  title={t("settings.profiles.deleteTitle", { name: profile.name })}
  message={removal.moving.length > 0 ? t("settings.profiles.deleteMessageSpaces") : t("settings.profiles.deleteMessage")}
  confirmLabel={t("settings.profiles.removeNamed", { name: profile.name })}
  confirmDisabled={!removal.removable}
  confirmAction={() => {
    confirmingRemove = false;
    profileActions.delete(profile.id, moveTo);
  }}
  cancelAction={() => (confirmingRemove = false)}
>
  {#if removal.moving.length > 0}
    <div class="move-row">
      <span>{t("settings.profiles.moveSpaces", { spaces: removal.moving.map((space) => `${space.icon} ${space.name}`).join(", ") })}</span>
      <UiSelect
        value={moveTo}
        options={removal.targets.map((target) => ({ value: target.id, label: target.name }))}
        ariaLabel={t("settings.profiles.moveTarget")}
        onchange={(value) => (moveTo = value)}
      />
    </div>
  {/if}
</BottomConfirmSheet>

<style>
  .profile-card {
    display: grid;
    align-content: start;
    gap: 12px;
    padding: 14px;
    border: 1px solid color-mix(in srgb, var(--profile-color) 40%, var(--border));
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--profile-color) 24%, var(--bg-primary));
  }

  .card-top {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
  }

  .card-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-primary);
    font-size: var(--font-size-lg);
    font-weight: var(--font-weight-semibold);
  }

  .rename-field {
    flex: 1;
    min-width: 0;
  }

  .menu-anchor {
    position: relative;
    margin-left: auto;
    flex: none;
  }

  .more-btn {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-secondary);
    cursor: pointer;
  }

  .more-btn:hover {
    color: var(--text-primary);
  }

  .more-btn:focus-visible {
    outline: var(--focus-outline);
  }

  .profile-menu {
    position: absolute;
    top: calc(100% + 4px);
    right: 0;
    z-index: 5;
    min-width: 180px;
  }

  .float-row.danger {
    color: var(--danger-text);
  }

  .float-row:disabled {
    opacity: var(--disabled-opacity);
    cursor: default;
  }

  .menu-separator {
    margin: 2px 6px;
    border-top: 1px solid var(--separator);
  }

  .recolor-row {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .mini-swatch {
    width: 20px;
    height: 20px;
    padding: 0;
    border: 1px solid var(--text-primary-tint-12);
    border-radius: 50%;
    cursor: pointer;
  }

  .mini-swatch.selected {
    box-shadow: 0 0 0 2px var(--bg-primary), 0 0 0 3.5px var(--text-primary);
  }

  .mini-swatch:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .chips {
    display: flex;
    min-width: 0;
    flex-wrap: wrap;
    gap: 6px;
  }

  .chip {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    max-width: 100%;
    padding: 4px 8px 4px 8px;
    border: 0;
    border-radius: var(--radius-chip);
    background: var(--bg-hover);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    white-space: nowrap;
    cursor: pointer;
  }

  .chip-name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  button.chip:hover {
    background: var(--text-primary-tint-12);
  }

  button.chip:focus-visible {
    outline: var(--focus-outline);
  }

  .chip.none {
    border: 1px dashed var(--border);
    background: transparent;
    color: var(--text-secondary);
    cursor: default;
  }

  /* Secondary, not muted: muted text falls under AA on the card's tint. */
  .stats {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
  }

  .move-row {
    display: grid;
    gap: 8px;
    margin-top: 12px;
    color: var(--text-primary);
    font-size: var(--font-size-md);
  }
</style>
