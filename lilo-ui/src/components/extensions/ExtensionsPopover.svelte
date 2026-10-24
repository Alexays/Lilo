<!-- Full extension list, opened from the address-bar cluster. Mounted on document.body so
     the address bar's overflow clipping never cuts it. -->
<script lang="ts">
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { tooltip } from "../../lib/tooltip";
  import { t } from "../../lib/i18n/state.svelte";
  import { extensionActions, tabActions } from "../../lib/bridge/actions";
  import { openSettings } from "../../stores/panels.svelte";
  import { getEnabledExtensions } from "../../stores/extensions.svelte";
  import {
    MAX_PINNED_EXTENSIONS,
    canPinMoreExtensions,
    getPinnedExtensionIds,
    isExtensionPinned,
    toggleExtensionPin,
  } from "../../stores/extensionPins.svelte";
  import {
    badgeTextColor,
    displayInitial,
    extensionIconSrc,
    resolveDisplayName,
  } from "./extensionPanelModel";

  const PANEL_WIDTH = 300;
  const WEB_STORE_URL = "https://chromewebstore.google.com";
  const VIEWPORT_MARGIN = 8;

  let { anchor, onclose }: { anchor: HTMLElement; onclose: () => void } =
    $props();

  const extensions = $derived(getEnabledExtensions());
  let rootEl = $state<HTMLDivElement>();

  // The popup anchors on the trigger, not on the row: the popover is gone by the time the
  // native panel opens.
  const anchorRect = $derived(anchor.getBoundingClientRect());
  const top = $derived(anchorRect.bottom + 6);
  const left = $derived(
    Math.max(
      VIEWPORT_MARGIN,
      Math.min(
        anchorRect.right - PANEL_WIDTH,
        window.innerWidth - PANEL_WIDTH - VIEWPORT_MARGIN,
      ),
    ),
  );

  function showExtensionMenu(event: MouseEvent, id: string): void {
    event.preventDefault();
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    extensionActions.showContextMenu(
      id,
      rect.x,
      rect.y,
      rect.width,
      rect.height,
      isExtensionPinned(id),
      canPinMoreExtensions(),
    );
  }

  function openExtensionPopup(id: string): void {
    extensionActions.openPopup(
      id,
      anchorRect.x,
      anchorRect.y,
      anchorRect.width,
      anchorRect.height,
    );
    onclose();
  }

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      event.preventDefault();
      anchor.focus();
      onclose();
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const items = Array.from(
      rootEl?.querySelectorAll<HTMLElement>(".ext-item, .footer-action") ?? [],
    );
    if (items.length === 0) return;
    event.preventDefault();
    const step = event.key === "ArrowDown" ? 1 : -1;
    const index = items.indexOf(document.activeElement as HTMLElement);
    const next =
      index < 0
        ? step > 0 ? 0 : items.length - 1
        : (index + step + items.length) % items.length;
    items[next]?.focus();
  }

  function pinTooltip(id: string): string {
    if (isExtensionPinned(id)) return t("extensions.unpinFromAddressBar");
    if (!canPinMoreExtensions())
      return t("extensions.pinLimitReached", { count: MAX_PINNED_EXTENSIONS });
    return t("extensions.pinToAddressBar");
  }

  $effect(() => {
    rootEl?.querySelector<HTMLElement>(".ext-item, .footer-action")?.focus();
  });

</script>

<div
  class="extensions-popover float-surface float-popover"
  role="menu"
  tabindex="-1"
  aria-label={t("extensions.addressBarMenu")}
  style="top:{top}px;left:{left}px;width:{PANEL_WIDTH}px;max-height:calc(100vh - {top + VIEWPORT_MARGIN}px)"
  bind:this={rootEl}
  {@attach dismissable({ onDismiss: onclose, ignore: ".extension-menu-btn", returnFocus: anchor })}
  onkeydown={handleKeydown}
  use:portal
  use:reportInteractiveZone={{ id: "extensions-popover" }}
>
  <div class="float-popover-head head">
    <span class="float-popover-title">{t("extensions.addressBarMenu")}</span>
    <span class="float-popover-subtitle">
      {t("extensions.pinnedCount", { pinned: getPinnedExtensionIds().length, max: MAX_PINNED_EXTENSIONS })}
    </span>
  </div>
  <div class="rows">
    {#each extensions as ext (ext.id)}
      <div class="extensions-popover-row">
        <button
          class="ext-item"
          class:action-disabled={!ext.actionEnabled}
          role="menuitem"
          use:tooltip={{ text: ext.actionLabel ?? "", placement: "right" }}
          aria-disabled={!ext.actionEnabled}
          onclick={() => ext.actionEnabled && openExtensionPopup(ext.id)}
          oncontextmenu={(event) => showExtensionMenu(event, ext.id)}
        >
          <span class="row-icon">
            {#if extensionIconSrc(ext)}
              <img
                class="row-icon-image"
                src={extensionIconSrc(ext)}
                alt=""
                draggable="false"
                onerror={(event) => {
                  (event.currentTarget as HTMLImageElement).hidden = true;
                }}
              />
            {:else}
              {displayInitial(ext)}
            {/if}
          </span>
          <span class="row-name">{resolveDisplayName(ext)}</span>
          {#if ext.badgeText}
            <span
              class="row-badge"
              style:background={ext.badgeColor || "var(--accent)"}
              style:color={badgeTextColor(ext.badgeColor, ext.badgeTextColor)}
            >
              {ext.badgeText}
            </span>
          {/if}
        </button>
        {#if ext.hostAccessRequest}
          <button
            class="row-allow"
            use:tooltip={t("extensions.hostAccessRequestTooltip")}
            onclick={() => extensionActions.acceptHostAccessRequest(ext.id)}
          >
            {t("extensions.hostAccessRequestAllow")}
          </button>
        {/if}
        <button
          class="row-pin"
          class:pinned={isExtensionPinned(ext.id)}
          disabled={!isExtensionPinned(ext.id) && !canPinMoreExtensions()}
          use:tooltip={pinTooltip(ext.id)}
          aria-label={pinTooltip(ext.id)}
          aria-pressed={isExtensionPinned(ext.id)}
          onclick={() => toggleExtensionPin(ext.id)}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill={isExtensionPinned(ext.id) ? "currentColor" : "none"} aria-hidden="true">
            <path
              d="M4.5 1.6h3M6 1.6v3.1c0 .5.2 1 .6 1.3l.9.8c.3.2.4.5.4.8H4.1c0-.3.1-.6.4-.8l.9-.8c.4-.3.6-.8.6-1.3V1.6M6 7.6v2.8"
              stroke="currentColor"
              stroke-width="1.15"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </button>
      </div>
    {/each}
  </div>
  <div class="footer">
    <button
      class="footer-action"
      role="menuitem"
      onclick={() => {
        openSettings("extensions");
        onclose();
      }}
    >
      {t("extensions.manageExtensions")}
    </button>
    <button
      class="footer-action"
      role="menuitem"
      onclick={() => {
        tabActions.create(WEB_STORE_URL);
        onclose();
      }}
    >
      {t("extensions.addExtensions")}
    </button>
  </div>
</div>

<style>
  .extensions-popover {
    position: fixed;
    z-index: var(--z-popover);
    transform-origin: calc(100% - 14px) 0;
  }

  .head {
    flex-direction: row;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
  }

  .rows {
    display: flex;
    flex-direction: column;
    gap: 2px;
    max-height: 360px;
    overflow-y: auto;
  }

  .extensions-popover-row {
    display: flex;
    align-items: center;
    gap: 2px;
    padding-right: 4px;
    border-radius: calc(var(--float-radius-popover) - 6px);
  }

  .extensions-popover-row:hover,
  .extensions-popover-row:focus-within {
    background: var(--bg-hover);
  }

  .ext-item {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 0;
    height: 28px;
    padding: 0 8px;
    border: none;
    border-radius: inherit;
    background: none;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
    cursor: pointer;
  }

  .ext-item:focus-visible {
    outline: none;
  }

  .ext-item.action-disabled {
    color: var(--text-secondary);
    cursor: default;
  }

  .ext-item.action-disabled .row-icon {
    opacity: var(--disabled-opacity);
  }

  .row-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    border-radius: var(--radius-xs);
    background: var(--bg-hover);
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-semibold);
  }

  .row-icon-image {
    width: 16px;
    height: 16px;
    object-fit: contain;
  }

  .row-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .row-badge {
    flex-shrink: 0;
    min-width: 15px;
    padding: 0 4px;
    border-radius: var(--radius-chip);
    color: var(--on-color);
    font-size: var(--font-size-3xs);
    font-weight: var(--font-weight-bold);
    line-height: 15px;
    text-align: center;
  }

  .row-allow {
    flex-shrink: 0;
    height: 22px;
    padding: 0 8px;
    border: none;
    border-radius: var(--radius-sm);
    background: var(--accent);
    color: var(--accent-text);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
  }

  .row-allow:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  /* Always shown: whether an extension is pinned reads at a glance, filled or outlined. */
  .row-pin {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    width: 22px;
    height: 22px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
  }

  .row-pin.pinned {
    color: var(--text-primary);
  }

  .row-pin:hover:not(:disabled) {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .row-pin:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .footer {
    display: flex;
    gap: 2px;
    padding-top: 4px;
    border-top: 1px solid var(--separator);
  }

  /* Sized by their labels, not halved: a long translation keeps to one line. */
  .footer-action {
    flex: 1 1 auto;
    white-space: nowrap;
    height: 26px;
    padding: 0 8px;
    border: none;
    border-radius: calc(var(--float-radius-popover) - 6px);
    background: none;
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .footer-action:hover,
  .footer-action:focus-visible {
    outline: none;
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .row-pin:disabled {
    color: color-mix(in srgb, var(--text-muted) 45%, transparent);
    cursor: default;
  }
</style>
