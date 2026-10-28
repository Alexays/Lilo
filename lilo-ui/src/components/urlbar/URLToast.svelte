<script lang="ts">
  import { dismissable } from "../../lib/actions/dismissable";
  import { tabActions } from "../../lib/bridge/actions";
  import ExtensionIcons from "../extensions/ExtensionIcons.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { tooltip } from "../../lib/tooltip";
  import { t } from "../../lib/i18n/state.svelte";
  import type { ToastVariant } from "../../lib/urlVisual";

  interface Props {
    toastVisible: boolean;
    toastVariant: ToastVariant;
    canInstall: boolean;
    isInstalled: boolean;
    blockerActive: boolean;
    isAllowlisted: boolean;
    blockedCount: number;
    onInstall: (e: MouseEvent) => void;
    onCopy: (e: Event) => void;
    onToggleBlocker: (e: MouseEvent) => void;
  }

  let {
    toastVisible,
    toastVariant,
    canInstall,
    isInstalled,
    blockerActive,
    isAllowlisted,
    blockedCount,
    onInstall,
    onCopy,
    onToggleBlocker,
  }: Props = $props();

  let screenshotMenuOpen = $state(false);
  let screenshotBtnEl = $state<HTMLElement | null>(null);
  let menuTop = $state(0);
  let menuRight = $state(0);

  // The menu hangs from the bar's bottom right corner, so it stays over the sidebar instead of the
  // page. Measured on the bar: the hovered button is lifted by a transform.
  function openMenu(e: MouseEvent) {
    e.stopPropagation();
    const bar = screenshotBtnEl?.closest(".url-trigger")?.getBoundingClientRect();
    if (!screenshotMenuOpen && bar) {
      menuTop = bar.bottom;
      menuRight = document.documentElement.clientWidth - bar.right;
    }
    screenshotMenuOpen = !screenshotMenuOpen;
  }

  // URLHost keeps the address text clear of the cluster and fades it out under the revealed
  // buttons, so it needs both live widths.
  function trackClusterWidth(node: HTMLElement) {
    const trigger = node.closest(".url-trigger");
    const reveal = node.querySelector<HTMLElement>(".url-actions-reveal");
    if (!(trigger instanceof HTMLElement) || !reveal) return;
    const observer = new ResizeObserver(() => {
      trigger.style.setProperty("--url-cluster-width", `${node.offsetWidth}px`);
      trigger.style.setProperty("--url-reveal-width", `${reveal.offsetWidth}px`);
    });
    observer.observe(node);
    observer.observe(reveal);
    return {
      destroy() {
        observer.disconnect();
        trigger.style.removeProperty("--url-cluster-width");
        trigger.style.removeProperty("--url-reveal-width");
      },
    };
  }

  function pickMode(mode: "full" | "viewport" | "region") {
    screenshotMenuOpen = false;
    tabActions.screenshotPage(mode);
  }
</script>

<span
  class="url-actions"
  class:has-toast={toastVisible}
  class:menu-open={screenshotMenuOpen}
  use:trackClusterWidth
>
  <span class="url-actions-reveal">
    {#if blockerActive && !toastVisible}
      <button
        class="url-action-btn url-blocker-btn"
        class:allowlisted={isAllowlisted}
        class:has-count={!isAllowlisted && blockedCount > 0}
        onclick={onToggleBlocker}
        use:tooltip={isAllowlisted
          ? t("urlToast.reEnableBlocking")
          : blockedCount > 0
            ? blockedCount > 1
              ? t("urlToast.trackersBlockedOnPage", { count: blockedCount })
              : t("urlToast.trackerBlockedOnPage", { count: blockedCount })
            : t("urlToast.disableBlocking")}
        aria-label={isAllowlisted
          ? t("urlToast.adsAllowed")
          : blockedCount > 0
            ? blockedCount > 1
              ? t("urlToast.trackersBlockedLabel", { count: blockedCount })
              : t("urlToast.trackerBlockedLabel", { count: blockedCount })
            : t("urlToast.adsBlocked")}
      >
        <svg width="11" height="13" viewBox="0 0 11 13" fill="none">
          <path d="M5.5 0.5L1 2.5V6.5C1 9.26 3 11.74 5.5 12.5C8 11.74 10 9.26 10 6.5V2.5L5.5 0.5Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>
          {#if isAllowlisted}
            <line x1="3" y1="3" x2="8.5" y2="10" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
          {/if}
        </svg>
        {#if !isAllowlisted && blockedCount > 0}<span class="blocker-count">{blockedCount}</span>{/if}
      </button>
    {/if}
    {#if canInstall}
      <span
        class="url-action-btn url-install-btn"
        class:is-installed={isInstalled}
        role="button"
        tabindex="0"
        use:tooltip={isInstalled
          ? t("urlToast.extensionAlreadyInstalled")
          : t("urlToast.installChromeExtension")}
        aria-disabled={isInstalled}
        onclick={(e) => {
          if (!isInstalled) {
            onInstall(e as MouseEvent);
          } else {
            e.stopPropagation();
          }
        }}
        onkeydown={(e) => {
          if ((e.key === "Enter" || e.key === " ") && !isInstalled) {
            e.preventDefault();
            onInstall(e as unknown as MouseEvent);
          }
        }}
      >
        {#if isInstalled}
          {t("urlToast.installed")}
        {:else}
          {t("urlToast.install")}
        {/if}
      </span>
    {/if}
    <span class="screenshot-menu-shell">
      <span
        class="url-action-btn url-screenshot-btn"
        class:active={screenshotMenuOpen}
        role="button"
        tabindex="0"
        use:tooltip={t("urlToast.screenshot")}
        aria-label={t("urlToast.screenshot")}
        aria-expanded={screenshotMenuOpen}
        bind:this={screenshotBtnEl}
        onclick={openMenu}
        onkeydown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            openMenu(e as unknown as MouseEvent);
          }
        }}
      >
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
          <path
            d="M5.5 3.5h-.75A1.75 1.75 0 0 0 3 5.25v6c0 .966.784 1.75 1.75 1.75h6.5A1.75 1.75 0 0 0 13 11.25v-6A1.75 1.75 0 0 0 11.25 3.5H10.5M5.5 3.5h5M5.5 3.5V2.75a.75.75 0 0 1 .75-.75h3.5a.75.75 0 0 1 .75.75V3.5"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
          <circle cx="8" cy="8.5" r="1.75" stroke="currentColor" stroke-width="1.4" />
        </svg>
      </span>

      {#if screenshotMenuOpen}
        <div
          class="screenshot-menu screenshot-menu-portal float-surface float-popover"
          role="menu"
          style="top:{menuTop}px;right:{menuRight}px"
          use:portal
          use:reportInteractiveZone={{ id: "screenshot-menu", active: true }}
          {@attach dismissable({ onDismiss: () => (screenshotMenuOpen = false), escape: true })}
        >
          <button class="float-row screenshot-menu-item" role="menuitem" onclick={() => pickMode("full")}>
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
              <rect x="2.5" y="1.5" width="11" height="13" rx="1.5" stroke="currentColor" stroke-width="1.4"/>
              <line x1="5" y1="5" x2="11" y2="5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
              <line x1="5" y1="8" x2="11" y2="8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
              <line x1="5" y1="11" x2="9" y2="11" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
            </svg>
            {t("urlToast.fullPage")}
          </button>
          <button class="float-row screenshot-menu-item" role="menuitem" onclick={() => pickMode("viewport")}>
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
              <rect x="1.5" y="2.5" width="13" height="11" rx="1.5" stroke="currentColor" stroke-width="1.4"/>
              <path d="M1.5 6h13" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
              <circle cx="4" cy="4.25" r="0.75" fill="currentColor"/>
              <circle cx="6.5" cy="4.25" r="0.75" fill="currentColor"/>
            </svg>
            {t("urlToast.visibleArea")}
          </button>
          <div class="screenshot-menu-separator"></div>
          <button class="float-row screenshot-menu-item" role="menuitem" onclick={() => pickMode("region")}>
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
              <path d="M3 6V3.5A1 1 0 0 1 4 2.5h2M10 2.5h2A1 1 0 0 1 13 3.5V6M13 10v2.5A1 1 0 0 1 12 13.5H10M6 13.5H4A1 1 0 0 1 3 12.5V10" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
            </svg>
            {t("urlToast.selection")}
          </button>
        </div>
      {/if}
    </span>
    <span
      class="url-action-btn url-copy-btn"
      class:copied={toastVisible &&
        toastVariant !== "failed" &&
        toastVariant !== "zoom"}
      role="button"
      tabindex="0"
      aria-label={t("urlToast.copyLink")}
      use:tooltip={t("urlToast.copyLink")}
      onclick={onCopy}
      onkeydown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onCopy(e);
        }
      }}
    >
      <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
        <path
          d="M6.75 9.25L9.25 6.75M7.25 4.75L8.29 3.71a2.83 2.83 0 0 1 4 4L11.25 8.75M8.75 11.25l-1.04 1.04a2.83 2.83 0 0 1-4-4L4.75 7.25"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </span>
  </span>

  <ExtensionIcons />
</span>

<style>
  /* Floats at the end of the bar; URLHost reserves its room through --url-cluster-width. */
  .url-actions {
    position: absolute;
    top: 50%;
    right: 6px;
    transform: translateY(-50%);
    display: flex;
    align-items: center;
    z-index: 2;
    flex-shrink: 0;
  }

  /* Overlays the address text on the cluster's left rather than pushing it, so hovering
     the bar never re-truncates the URL. */
  .url-actions-reveal {
    position: absolute;
    top: 50%;
    right: calc(100% + 4px);
    display: flex;
    align-items: center;
    gap: 4px;
    opacity: 0;
    pointer-events: none;
    transform: translateY(-50%) translateX(8px) scale(0.94);
    transition:
      opacity var(--motion-duration-normal) ease,
      transform 260ms var(--motion-ease-spring);
  }

  /* On the Space row there is no address to cover: the buttons stay out, in line. */
  :global(.actions-only) .url-actions,
  :global(.actions-only) .url-actions-reveal {
    position: static;
    opacity: 1;
    pointer-events: auto;
    transform: none;
  }

  :global(.actions-only) .url-actions-reveal {
    margin-right: 4px;
  }

  /* Idle, they wear the extension icons' discreet face and wake up with them on hover. */
  :global(.actions-only:not(:hover, :focus-within)) .url-action-btn:not(.active, .copied) {
    background: color-mix(in srgb, var(--text-primary) 8%, transparent) !important;
  }

  .url-blocker-btn {
    color: var(--success-vivid);
    background: color-mix(in srgb, var(--success) 20%, var(--bg-active)) !important;
  }

  .url-blocker-btn.has-count {
    width: auto;
    min-width: 20px;
    padding: 0 6px 0 4px;
    gap: 4px;
  }

  .url-blocker-btn .blocker-count {
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-bold);
    line-height: 1;
    font-variant-numeric: tabular-nums;
  }

  .url-blocker-btn:hover {
    background: color-mix(in srgb, var(--success) 28%, var(--bg-active)) !important;
    color: color-mix(in srgb, var(--success) 88%, white 12%);
    transform: translateY(-1px) scale(1.03);
  }

  .url-blocker-btn.allowlisted {
    color: var(--text-muted);
    background: var(--bg-active) !important;
  }

  .url-blocker-btn.allowlisted:hover {
    color: var(--danger-vivid);
    background: color-mix(in srgb, var(--danger-vivid) 12%, var(--bg-active)) !important;
    transform: translateY(-1px) scale(1.03);
  }

  :global(.url-trigger:hover) .url-actions-reveal,
  :global(.url-trigger:focus-within) .url-actions-reveal,
  .url-actions.has-toast .url-actions-reveal,
  .url-actions.menu-open .url-actions-reveal {
    opacity: 1;
    pointer-events: auto;
    transform: translateY(-50%) translateX(0) scale(1);
  }

  /* The revealed buttons have gaps between them: URLHost fades the address out under them. */
  :global(.url-trigger:is(:hover, :focus-within, :has(.url-actions.has-toast, .url-actions.menu-open)) .url-text-shell) {
    --url-reveal-mask: 0;
  }

  .url-action-btn {
    width: 20px;
    min-width: 20px;
    height: 20px;
    border: none;
    background: var(--bg-active);
    color: var(--text-secondary);
    cursor: pointer;
    border-radius: var(--radius-sm);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    position: relative;
    z-index: 1;
    transition:
      background var(--transition-fast),
      color var(--transition-fast),
      transform 180ms var(--motion-ease-spring);
  }

  .url-action-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .url-install-btn {
    width: auto;
    padding: 0 8px;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    background: var(--accent-tint-12);
    color: var(--text-primary);
  }

  .url-install-btn.is-installed {
    background: color-mix(in srgb, var(--bg-active) 72%, transparent);
    color: var(--text-muted);
    cursor: default;
  }

  .url-action-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
    transform: translateY(-1px) scale(1.03);
  }

  .url-copy-btn {
    background: color-mix(
      in srgb,
      var(--text-primary) 18%,
      var(--bg-active)
    );
    color: var(--text-primary);
  }

  .url-copy-btn:hover {
    background: color-mix(in srgb, var(--accent) 14%, var(--bg-active));
    color: var(--accent);
  }

  .url-install-btn.is-installed:hover {
    background: color-mix(in srgb, var(--bg-active) 72%, transparent);
    color: var(--text-muted);
    transform: none;
  }

  .url-copy-btn.copied {
    background: var(--accent-tint-10);
    color: var(--accent);
    animation: url-copy-button-pop 540ms var(--motion-ease-bounce);
  }

  .url-screenshot-btn {
    background: color-mix(
      in srgb,
      var(--text-primary) 18%,
      var(--bg-active)
    );
    color: var(--text-primary);
  }

  .url-screenshot-btn:hover,
  .url-screenshot-btn.active {
    background: var(--accent);
    color: var(--accent-text);
  }

  .screenshot-menu-shell {
    position: relative;
  }

  .screenshot-menu {
    position: fixed;
    min-width: 168px;
    z-index: var(--z-popover);
    gap: 2px;
    transform-origin: 100% 0;
  }

  .screenshot-menu-item svg {
    flex: none;
    color: var(--text-secondary);
  }

  .screenshot-menu-separator {
    height: 1px;
    background: var(--separator);
    margin: 2px 8px;
  }

  @keyframes url-copy-button-pop {
    0% {
      transform: scale(1);
    }

    35% {
      transform: translateY(-1px) scale(1.12);
    }

    100% {
      transform: scale(1);
    }
  }
</style>
