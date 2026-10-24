<script lang="ts">
  import UiButton from "../ui/UiButton.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import ExtensionSpinner from "./ExtensionSpinner.svelte";
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
    isExtensionDegraded,
    resolveDisplayName,
    type ExtensionCapability,
  } from "./extensionPanelModel";
  import { t } from "../../lib/i18n/state.svelte";

  interface Props {
    extension: ExtensionState;
    onopen: () => void;
    onmenu: (anchor: DOMRect) => void;
  }

  let { extension, onopen, onmenu }: Props = $props();

  const META_LABEL_KEYS: Record<ExtensionCapability, string> = {
    popup: "extensions.badgePopup",
    background: "extensions.badgeBackground",
    content: "extensions.badgeContent",
  };

  const name = $derived(resolveDisplayName(extension));
  const pending = $derived(isExtensionPending(extension.id));
  const errored = $derived(hasExtensionError(extension.id));
  const degraded = $derived(isExtensionDegraded(extension));
  const failed = $derived(extension.runtimeStatus === "failed");
  const updating = $derived(isExtensionUpdating(extension.id));
  const metaLine = $derived(
    failed
      ? extension.error || t("extensions.failedTitle")
      : [
          `v${extension.version}`,
          ...extensionCapabilities(extension).map((c) => t(META_LABEL_KEYS[c])),
          ...(extension.declinedUpdate
            ? [t("extensions.needsPermissions")]
            : extension.availableUpdate
              ? [t("extensions.updateAvailable", { version: extension.availableUpdate })]
              : []),
        ].join(" · "),
  );
</script>

<div class="extension-row" class:disabled={!extension.isEnabled && !failed}>
  <button
    class="row-main"
    type="button"
    onclick={onopen}
    aria-label={t("extensions.openDetailsLabel", { name })}
  >
    <span class="row-icon" aria-hidden="true">
      {#if extensionIconSrc(extension)}
        <img
          class="row-icon-image"
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
    <span class="row-copy">
      <span class="row-name">{name}</span>
      <span class="row-meta" class:failed title={metaLine}>{metaLine}</span>
    </span>
  </button>

  {#if degraded}
    <span
      class="row-degraded"
      title={extension.error || t("extensions.degradedTitle")}
      aria-label={t("extensions.degradedTitle")}
      role="img"
    ></span>
  {/if}

  {#if errored}
    <button
      class="row-error"
      type="button"
      title={t("extensions.actionFailed")}
      aria-label={t("extensions.actionFailed")}
      onclick={() => clearExtensionError(extension.id)}
    >
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
        <circle cx="7" cy="7" r="6" stroke="currentColor" stroke-width="1.3" />
        <path d="M7 4v3.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
        <circle cx="7" cy="10" r="0.7" fill="currentColor" />
      </svg>
    </button>
  {/if}

  {#if pending || updating}
    <ExtensionSpinner />
  {/if}

  {#if failed}
    <UiButton disabled={pending} onclick={() => enableExtension(extension.id, extension.profileId)}>{t("extensions.retry")}</UiButton>
  {:else}
    {#if extension.declinedUpdate || extension.availableUpdate}
      <UiButton disabled={updating} onclick={() => updateExtension(extension.id, extension.profileId)}>
        {extension.declinedUpdate ? t("extensions.review") : t("extensions.update")}
      </UiButton>
    {/if}
    <UiToggle
      checked={extension.isEnabled}
      disabled={pending}
      ariaLabel={t("extensions.enabledToggleLabel", { name })}
      onchange={(checked) =>
        checked ? enableExtension(extension.id, extension.profileId) : disableExtension(extension.id, extension.profileId)}
    />
  {/if}

  <button
    class="row-menu"
    type="button"
    aria-label={t("extensions.menuButtonLabel", { name })}
    onclick={(event) => onmenu(event.currentTarget.getBoundingClientRect())}
  >
    <svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor" aria-hidden="true">
      <circle cx="2.5" cy="7" r="1.3" />
      <circle cx="7" cy="7" r="1.3" />
      <circle cx="11.5" cy="7" r="1.3" />
    </svg>
  </button>
</div>

<style>
  .extension-row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 10px;
    background: var(--bg-elevated);
    border-radius: var(--radius-md);
    border: 1px solid var(--border);
    min-width: 0;
  }

  .row-main {
    flex: 1;
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    padding: 0;
    background: none;
    border: none;
    text-align: left;
    cursor: pointer;
    color: inherit;
    font: inherit;
  }

  .extension-row.disabled .row-main {
    opacity: var(--disabled-opacity);
  }

  .row-icon {
    position: relative;
    width: 30px;
    height: 30px;
    border-radius: var(--radius-sm);
    background: var(--accent);
    color: var(--accent-text);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: var(--font-size-lg);
    font-weight: var(--font-weight-bold);
    flex-shrink: 0;
    overflow: hidden;
  }

  /* The accent tile backs only the initial: a loaded logo sits on the row as it is. */
  .row-icon:has(> img:not([hidden])) {
    background: transparent;
    color: transparent;
  }

  .row-icon-image {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
  }

  .row-copy {
    display: grid;
    gap: 2px;
    min-width: 0;
  }

  .row-name {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .row-meta {
    font-size: var(--font-size-xs);
    color: var(--text-muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .row-meta.failed {
    color: var(--danger-text);
  }

  .row-degraded {
    flex-shrink: 0;
    width: 8px;
    height: 8px;
    border-radius: var(--radius-chip);
    background: var(--warning);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--warning) 25%, transparent);
  }

  .row-error {
    flex-shrink: 0;
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    padding: 0;
    background: none;
    border: none;
    border-radius: var(--radius-sm);
    color: var(--danger-text);
    cursor: pointer;
  }

  .row-error:hover {
    background: color-mix(in srgb, var(--danger-deep) 10%, transparent);
  }

  .row-menu {
    flex-shrink: 0;
    width: 24px;
    height: 24px;
    display: grid;
    place-items: center;
    padding: 0;
    background: none;
    border: none;
    border-radius: var(--radius-sm);
    color: var(--text-muted);
    cursor: pointer;
  }

  .row-menu:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }
</style>
