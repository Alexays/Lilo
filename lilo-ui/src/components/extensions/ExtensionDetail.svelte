<script lang="ts">
  import SettingsGroupIcon from "../settings/SettingsGroupIcon.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiTextField from "../ui/UiTextField.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import ExtensionSpinner from "./ExtensionSpinner.svelte";
  import { extensionActions } from "../../lib/bridge/actions";
  import {
    clearExtensionError,
    disableExtension,
    enableExtension,
    hasExtensionError,
    isExtensionPending,
    isExtensionUpdating,
    updateExtension,
    type ExtensionState,
  } from "../../stores/extensions.svelte";
  import {
    displayInitial,
    extensionCapabilities,
    extensionIconSrc,
    formatShortcut,
    isExtensionDegraded,
    normalizeSiteHost,
    permissionChips,
    resolveDisplayName,
    shortcutFromKeyEvent,
    type ExtensionCapability,
  } from "./extensionPanelModel";
  import { t } from "../../lib/i18n/state.svelte";

  interface Props {
    extension: ExtensionState;
    onremove: () => void;
  }

  let { extension, onremove }: Props = $props();

  const DETAIL_LABEL_KEYS: Record<ExtensionCapability, string> = {
    popup: "extensions.capabilityPopup",
    background: "extensions.capabilityBackground",
    content: "extensions.capabilityContent",
  };

  const name = $derived(resolveDisplayName(extension));
  const capabilities = $derived(extensionCapabilities(extension));
  const permissions = $derived(permissionChips(extension));
  const pending = $derived(isExtensionPending(extension.id));
  const errored = $derived(hasExtensionError(extension.id));
  const degraded = $derived(isExtensionDegraded(extension));
  const updating = $derived(isExtensionUpdating(extension.id));
  let recordingCommand = $state<string | null>(null);

  // Chrome's name for the toolbar action's command, which manifests leave untitled.
  function commandTitle(command: { id: string; title: string }): string {
    if (command.title) return command.title;
    return command.id === "_execute_action" ? t("extensions.executeAction") : command.id;
  }

  // Escape cancels; Delete or Backspace removes the shortcut.
  function recordShortcut(event: KeyboardEvent, command: string): void {
    if (recordingCommand !== command || event.key === "Tab") return;
    event.preventDefault();
    if (event.key === "Escape") {
      recordingCommand = null;
    } else if (event.key === "Backspace" || event.key === "Delete") {
      extensionActions.setCommandShortcut(extension.id, command, "", 0);
      recordingCommand = null;
    } else {
      const shortcut = shortcutFromKeyEvent(event);
      if (!shortcut) return;
      extensionActions.setCommandShortcut(extension.id, command, shortcut.key, shortcut.modifiers);
      recordingCommand = null;
    }
  }

  // An extension with no host access has nothing to restrict.
  const wantsHosts = $derived(
    (extension.hostPermissions?.length ?? 0) > 0 || extension.hasContentScripts,
  );
  const sites = $derived(extension.siteAccess ?? []);
  let siteDraft = $state("");
  // Remounts the site field once a host is added, which empties it.
  let siteFieldKey = $state(0);
  const draftHost = $derived(normalizeSiteHost(siteDraft));

  function addSite() {
    if (!draftHost) return;
    if (!sites.includes(draftHost)) extensionActions.setSiteAccess(extension.id, [...sites, draftHost]);
    siteDraft = "";
    siteFieldKey += 1;
  }

  function removeSite(host: string) {
    extensionActions.setSiteAccess(
      extension.id,
      sites.filter((site) => site !== host),
    );
  }
</script>

<!-- The shell's header names the extension: the page opens on its state, built from the settings lists. -->
<div class="extension-detail">
  {#if degraded}
    <div class="detail-notice" role="status">
      <span class="detail-notice-dot" aria-hidden="true"></span>
      <span class="detail-notice-text">{t("extensions.degradedTitle")}{extension.error ? ` ${extension.error}` : ""}</span>
    </div>
  {:else if extension.runtimeStatus === "failed"}
    <div class="detail-notice detail-failed" role="alert">
      <span class="detail-notice-text">{t("extensions.failedTitle")}{extension.error ? ` ${extension.error}` : ""}</span>
      <UiButton disabled={pending} onclick={() => enableExtension(extension.id)}>{t("extensions.retry")}</UiButton>
    </div>
  {/if}

  {#if extension.declinedUpdate || extension.availableUpdate}
    <div class="detail-notice" role="status">
      <span class="detail-notice-text">
        {extension.declinedUpdate
          ? t("extensions.updateNeedsPermissions", { version: extension.declinedUpdate })
          : t("extensions.updateAvailable", { version: extension.availableUpdate ?? "" })}
      </span>
      {#if updating}
        <ExtensionSpinner />
      {/if}
      <UiButton disabled={updating} onclick={() => updateExtension(extension.id)}>
        {extension.declinedUpdate ? t("extensions.review") : t("extensions.update")}
      </UiButton>
    </div>
  {/if}

  {#if errored}
    <button class="detail-notice detail-failed detail-error" type="button" onclick={() => clearExtensionError(extension.id)}>
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
        <circle cx="7" cy="7" r="6" stroke="currentColor" stroke-width="1.3" />
        <path d="M7 4v3.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
        <circle cx="7" cy="10" r="0.7" fill="currentColor" />
      </svg>
      {t("extensions.actionFailed")}
    </button>
  {/if}

  <UiInsetList>
    <UiListRow title={t("extensions.detailEnabled")} description={`v${extension.version} · ${extension.id}`}>
      {#snippet icon()}
        <span class="detail-icon">
          {#if extensionIconSrc(extension)}
            <img
              src={extensionIconSrc(extension)}
              alt=""
              draggable="false"
              onerror={(event) => {
                (event.currentTarget as HTMLImageElement).hidden = true;
              }}
              onload={(event) => {
                (event.currentTarget as HTMLImageElement).hidden = false;
              }}
            />
          {/if}
          {displayInitial(extension)}
        </span>
      {/snippet}
      {#snippet action()}
        {#if pending}
          <ExtensionSpinner />
        {/if}
        <UiToggle
          checked={extension.isEnabled}
          disabled={pending}
          ariaLabel={t("extensions.enabledToggleLabel", { name })}
          onchange={(checked) => (checked ? enableExtension(extension.id) : disableExtension(extension.id))}
        />
      {/snippet}
    </UiListRow>
    {#if extension.runtimeStatus !== "failed"}
      <UiListRow title={t("extensions.allowPrivate")} description={t("extensions.allowPrivateHint")}>
        {#snippet action()}
          <UiToggle
            checked={extension.allowsPrivateAccess ?? false}
            ariaLabel={t("extensions.allowPrivate")}
            onchange={(checked) => extensionActions.setPrivateAccess(extension.id, checked)}
          />
        {/snippet}
      </UiListRow>
      {#if extension.permissions?.includes("userScripts")}
        <UiListRow title={t("extensions.allowUserScripts")} description={t("extensions.allowUserScriptsHint")}>
          {#snippet action()}
            <UiToggle
              checked={extension.allowsUserScripts ?? false}
              ariaLabel={t("extensions.allowUserScripts")}
              onchange={(checked) => extensionActions.setUserScripts(extension.id, checked)}
            />
          {/snippet}
        </UiListRow>
      {/if}
    {/if}
  </UiInsetList>

  {#if extension.description}
    <UiInsetList title={t("extensions.detailDescription")}>
      {#snippet icon()}<SettingsGroupIcon group="extensions.detailDescription" />{/snippet}
      <p class="detail-text">{extension.description}</p>
    </UiInsetList>
  {/if}

  {#if capabilities.length > 0}
    <UiInsetList title={t("extensions.detailCapabilities")}>
      {#snippet icon()}<SettingsGroupIcon group="extensions.detailCapabilities" />{/snippet}
      <p class="detail-text">{capabilities.map((capability) => t(DETAIL_LABEL_KEYS[capability])).join(" · ")}</p>
    </UiInsetList>
  {/if}

  {#if permissions.length > 0}
    <UiInsetList title={t("extensions.detailPermissions")}>
      {#snippet icon()}<SettingsGroupIcon group="extensions.detailPermissions" />{/snippet}
      <p class="detail-text detail-chips">
        {#each permissions as permission (permission)}<span class="detail-chip">{permission}</span>{/each}
      </p>
    </UiInsetList>
  {/if}

  {#if extension.commands?.length}
    <UiInsetList title={t("extensions.detailShortcuts")}>
      {#snippet icon()}<SettingsGroupIcon group="extensions.detailShortcuts" />{/snippet}
      {#each extension.commands as command (command.id)}
        <UiListRow title={commandTitle(command)}>
          {#snippet action()}
            <button
              class="detail-shortcut"
              class:recording={recordingCommand === command.id}
              type="button"
              aria-label={t("extensions.shortcutChange", { command: commandTitle(command) })}
              onmousedown={(event) => event.preventDefault()}
              onclick={(event) => {
                // WebKit never focuses a clicked button, and keydown only reaches a focused one.
                event.currentTarget.focus();
                recordingCommand = recordingCommand === command.id ? null : command.id;
              }}
              onkeydown={(event) => recordShortcut(event, command.id)}
              onblur={() => (recordingCommand = null)}
            >
              {recordingCommand === command.id
                ? t("extensions.shortcutRecording")
                : command.key
                  ? formatShortcut(command.key, command.modifiers)
                  : t("extensions.shortcutNone")}
            </button>
          {/snippet}
        </UiListRow>
      {/each}
    </UiInsetList>
  {/if}

  {#if wantsHosts}
    <UiInsetList title={t("extensions.detailSiteAccess")}>
      {#snippet icon()}<SettingsGroupIcon group="extensions.detailSiteAccess" />{/snippet}
      <UiListRow title={sites.length === 0 ? t("extensions.siteAccessAll") : t("extensions.siteAccessRestricted")}>
        {#if sites.length > 0}
          <span class="detail-chips">
            {#each sites as host (host)}
              <span class="detail-chip">
                {host}
                <button
                  class="detail-chip-remove"
                  type="button"
                  aria-label={t("extensions.siteAccessRemove", { host })}
                  onclick={() => removeSite(host)}
                >
                  <svg width="8" height="8" viewBox="0 0 8 8" fill="none" aria-hidden="true">
                    <path d="M1 1l6 6M7 1L1 7" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
                  </svg>
                </button>
              </span>
            {/each}
          </span>
        {/if}
        <span class="detail-site-add">
          {#key siteFieldKey}
            <UiTextField
              placeholder={t("extensions.siteAccessPlaceholder")}
              ariaLabel={t("extensions.detailSiteAccess")}
              onchange={(value) => (siteDraft = value)}
              oncommit={addSite}
            />
          {/key}
          <UiButton disabled={!draftHost} onclick={addSite}>{t("extensions.siteAccessAdd")}</UiButton>
        </span>
      </UiListRow>
    </UiInsetList>
  {/if}

  <UiInsetList>
    <UiListRow title={t("extensions.removeTitle")} description={t("extensions.removeConfirmMessage")}>
      {#snippet action()}
        <UiButton variant="danger" disabled={pending} onclick={onremove}>{t("common.remove")}</UiButton>
      {/snippet}
    </UiListRow>
  </UiInsetList>
</div>

<style>
  .extension-detail {
    display: grid;
    gap: 22px;
  }

  .detail-icon {
    position: relative;
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    overflow: hidden;
    border-radius: var(--radius-sm);
    background: var(--accent);
    color: var(--accent-text);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-bold);
  }

  .detail-icon img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
  }

  .extension-detail :global(.ui-list-row-icon:has(.detail-icon)) {
    width: 28px;
  }

  .detail-text {
    margin: 0;
    padding: 10px 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.45;
    overflow-wrap: anywhere;
  }

  .detail-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
  }

  .detail-chip {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 8px;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-secondary);
    font-family: ui-monospace, monospace;
    font-size: var(--font-size-xs);
    overflow-wrap: anywhere;
  }

  .detail-chip-remove {
    display: inline-grid;
    place-items: center;
    width: 14px;
    height: 14px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-xs);
    background: none;
    color: inherit;
    cursor: pointer;
  }

  .detail-chip-remove:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .detail-site-add {
    display: flex;
    gap: 8px;
    margin-top: 6px;
  }

  /* Same look as the keyboard shortcuts page's keys. */
  .detail-shortcut {
    min-height: 24px;
    padding: 2px 8px;
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    letter-spacing: 0.08em;
    white-space: nowrap;
    cursor: pointer;
  }

  .detail-shortcut:hover {
    background: var(--bg-active);
  }

  .detail-shortcut.recording {
    outline: 1.5px solid var(--accent);
    letter-spacing: normal;
  }

  .detail-notice {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    border: 0;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--attention) 14%, transparent);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
  }

  .detail-notice-dot {
    flex: none;
    width: 8px;
    height: 8px;
    border-radius: var(--radius-chip);
    background: var(--attention);
  }

  .detail-failed {
    background: color-mix(in srgb, var(--danger) 12%, transparent);
    color: var(--danger-text);
  }

  .detail-error {
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
  }

  .detail-notice-text {
    flex: 1;
    min-width: 0;
    overflow-wrap: anywhere;
  }
</style>
