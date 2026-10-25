<!-- Address-bar extension cluster: the pinned actions, then the trigger that opens the full
     list. Always visible, unlike the hover-revealed URL actions next to it. -->
<script lang="ts" module>
  // A Remove picked here opens the settings page, which mounts after the event and reads it once.
  let pendingRemovalId: string | null = null;

  export function takePendingExtensionRemoval(): string | null {
    const id = pendingRemovalId;
    pendingRemovalId = null;
    return id;
  }
</script>

<script lang="ts">
  import { flip } from "svelte/animate";
  import { cubicOut } from "svelte/easing";
  import ExtensionsPopover from "./ExtensionsPopover.svelte";
  import {
    getEnabledExtensions,
    type ExtensionState,
  } from "../../stores/extensions.svelte";
  import { getPinnedExtensionIds } from "../../stores/extensionPins.svelte";
  import {
    getSettingsShellSection,
    isSettingsShellOpen,
    openSettings,
    openSettingsSubpage,
  } from "../../stores/panels.svelte";
  import { on } from "../../lib/bridge";
  import { extensionActions } from "../../lib/bridge/actions";
  import { tooltip } from "../../lib/tooltip";
  import { createFrameScheduler } from "../../lib/motion/frameScheduler";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    badgeTextColor,
    displayInitial,
    extensionIconSrc,
    fitPinnedCount,
    resolveDisplayName,
  } from "./extensionPanelModel";

  const extensions = $derived(getEnabledExtensions());
  const pinnedIds = $derived(
    getPinnedExtensionIds().filter((id) => extensions.some((ext) => ext.id === id)),
  );
  // The address bar's width, set by the resize observer below. Only a change of the count reaches
  // the icons, so a sidebar drag never re-renders them between two fits.
  let barWidth = $state(0);
  const inlineCount = $derived(fitPinnedCount(barWidth, pinnedIds.length));
  const inlineIds = $derived(pinnedIds.slice(0, inlineCount));
  const pinned = $derived(
    inlineIds.map((id) => extensions.find((ext) => ext.id === id) as ExtensionState),
  );
  // A badge on a folded-away extension would be invisible otherwise.
  const hasFoldedBadge = $derived(
    extensions.some((ext) => ext.badgeText && !inlineIds.includes(ext.id)),
  );

  // Switching to a space on another profile swaps the whole extension set. The incoming icons
  // mount at once so they ride the space switch, and the outgoing ones leave the flow on the
  // spot: the row takes its new width immediately and the address reserve slides to follow.
  const SWAP_OUT_MS = 140;

  function floatOut(node: HTMLElement) {
    // Measured from the right edge, which is the cluster's anchor: the ghost then holds its
    // place on screen even as the row narrows around it. Rects, not offsets: a flip in progress
    // has already moved it.
    const box = node.getBoundingClientRect();
    const container = node.parentElement?.getBoundingClientRect() ?? box;
    // Out of the flow now, not on the outro's first frame: animate:flip measures where the icons
    // that stay land right after this, and Svelte's own fix skips an icon still animating.
    const inline = node.style.cssText;
    node.style.cssText +=
      `;position: absolute; right: ${container.right - box.right}px;` +
      `top: ${box.top - container.top}px; transform: none`;
    return {
      duration: prefersReducedMotion() ? 0 : SWAP_OUT_MS,
      easing: cubicOut,
      css: (t: number) => `opacity: ${t}; transform: scale(${0.55 + 0.45 * t});`,
      // An icon back before it is gone (the sidebar widened again) gets its outro reset at t = 1,
      // once Svelte has lifted the outro's inert.
      tick: (t: number) => {
        if (t === 1 && !node.inert) node.style.cssText = inline;
      },
    };
  }

  let popoverOpen = $state(false);
  let triggerEl = $state<HTMLElement | null>(null);

  let clusterEl = $state<HTMLElement | null>(null);
  // eslint-disable-next-line svelte/prefer-svelte-reactivity -- measured from a frame callback, never rendered
  const pinnedAnchors = new Map<string, HTMLElement>();
  const anchorFrame = createFrameScheduler();

  // Last rect sent per id, rebuilt on every report so ids that leave the cluster drop out.
  let sentAnchors = new Map<string, DOMRect>();

  function reportPopupAnchors(): void {
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- measured from a frame callback, never rendered
    const next = new Map<string, DOMRect>();
    for (const [id, node] of pinnedAnchors) next.set(id, node.getBoundingClientRect());
    // Folded-away extensions anchor a shortcut-opened popup (_execute_action) on the menu button.
    if (triggerEl && foldedIds) {
      const rect = triggerEl.getBoundingClientRect();
      for (const id of foldedIds.split(",")) next.set(id, rect);
    }
    for (const [id, rect] of next) {
      const sent = sentAnchors.get(id);
      if (
        sent &&
        sent.x === rect.x &&
        sent.y === rect.y &&
        sent.width === rect.width &&
        sent.height === rect.height
      ) {
        continue;
      }
      extensionActions.updatePopupAnchor(id, rect.x, rect.y, rect.width, rect.height);
    }
    sentAnchors = next;
  }

  const schedulePopupAnchors = () => anchorFrame.schedule(reportPopupAnchors);

  function reportPopupAnchor(node: HTMLElement, id: string) {
    pinnedAnchors.set(id, node);
    schedulePopupAnchors();
    return {
      update(nextId: string) {
        if (pinnedAnchors.get(id) === node) pinnedAnchors.delete(id);
        id = nextId;
        pinnedAnchors.set(id, node);
        schedulePopupAnchors();
      },
      destroy() {
        if (pinnedAnchors.get(id) === node) pinnedAnchors.delete(id);
      },
    };
  }

  const foldedIds = $derived(
    extensions
      .filter((ext) => !inlineIds.includes(ext.id))
      .map((ext) => ext.id)
      .join(","),
  );
  $effect(() => {
    if (triggerEl && foldedIds) schedulePopupAnchors();
  });

  // The address bar resizes with the sidebar, and the cluster as icons come and go: both move
  // the anchors without resizing the icons themselves.
  $effect(() => {
    const cluster = clusterEl;
    const bar = cluster?.closest(".url-trigger");
    if (!cluster || !bar) return;
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        if (entry.target === bar) barWidth = entry.borderBoxSize[0].inlineSize;
      }
      schedulePopupAnchors();
    });
    observer.observe(bar);
    observer.observe(cluster);
    window.addEventListener("resize", schedulePopupAnchors);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", schedulePopupAnchors);
    };
  });

  // Details and Remove from this cluster's menu: the settings page handles them once it shows.
  $effect(() =>
    on("extensionMenuAction", (data) => {
      if (data.action === "togglePin") return;
      if (isSettingsShellOpen() && getSettingsShellSection() === "extensions") return;
      if (data.action === "remove") pendingRemovalId = data.id;
      openSettings("extensions");
      openSettingsSubpage("extensions", `extension:${data.id}`);
    }),
  );

  function openExtensionPopup(event: MouseEvent, ext: ExtensionState): void {
    event.stopPropagation();
    if (!ext.actionEnabled) return;
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    extensionActions.openPopup(ext.id, rect.x, rect.y, rect.width, rect.height);
  }

  function showExtensionMenu(event: MouseEvent, id: string): void {
    event.preventDefault();
    event.stopPropagation();
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    extensionActions.showContextMenu(
      id,
      rect.x,
      rect.y,
      rect.width,
      rect.height,
      true,
    );
  }
</script>

{#if extensions.length > 0}
  <span class="extension-cluster" bind:this={clusterEl}>
    {#each pinned as ext, index (ext.id)}
      <button
        class="extension-icon"
        class:action-disabled={!ext.actionEnabled}
        style={`--icon-index: ${index}`}
        animate:flip={{ duration: prefersReducedMotion() ? 0 : 260, easing: cubicOut }}
        out:floatOut|global
        use:reportPopupAnchor={ext.id}
        use:tooltip={{
          text: ext.actionLabel || resolveDisplayName(ext),
          iconSrc: extensionIconSrc(ext),
        }}
        aria-label={ext.actionLabel || resolveDisplayName(ext)}
        aria-disabled={!ext.actionEnabled}
        onclick={(event) => openExtensionPopup(event, ext)}
        oncontextmenu={(event) => showExtensionMenu(event, ext.id)}
        onkeydown={(event) => event.stopPropagation()}
      >
        <span class="extension-icon-face">
          {#if extensionIconSrc(ext)}
            <img
              class="ext-icon-image"
              src={extensionIconSrc(ext)}
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
          <span class="ext-initial">{displayInitial(ext)}</span>
        </span>
        {#if ext.badgeText}
          <span
            class="badge"
            style:background={ext.badgeColor || "var(--accent)"}
            style:color={badgeTextColor(ext.badgeColor, ext.badgeTextColor)}
          >
            {ext.badgeText}
          </span>
        {/if}
      </button>
    {/each}

    <button
      class="extension-icon extension-menu-btn"
      class:active={popoverOpen}
      out:floatOut|global
      bind:this={triggerEl}
      use:tooltip={t("extensions.addressBarMenu")}
      aria-label={t("extensions.addressBarMenu")}
      aria-expanded={popoverOpen}
      onclick={(event) => {
        event.stopPropagation();
        popoverOpen = !popoverOpen;
      }}
      onkeydown={(event) => event.stopPropagation()}
    >
      <span class="extension-icon-face">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
          <path
            d="M3.4 2.8h3a1.6 1.6 0 0 1 3.2 0h3c.5 0 .9.4.9.9v3a1.6 1.6 0 0 0 0 3.2v3c0 .5-.4.9-.9.9H3.4a.9.9 0 0 1-.9-.9v-3a1.6 1.6 0 0 0 0-3.2v-3c0-.5.4-.9.9-.9Z"
            stroke="currentColor"
            stroke-width="1.2"
            stroke-linejoin="round"
          />
        </svg>
      </span>
      {#if hasFoldedBadge}
        <span class="cluster-dot" aria-hidden="true"></span>
      {/if}
    </button>

    {#if popoverOpen && triggerEl}
      <ExtensionsPopover
        anchor={triggerEl}
        overflowIds={pinnedIds.slice(inlineCount)}
        onclose={() => {
          popoverOpen = false;
        }}
      />
    {/if}
  </span>
{/if}

<style>
  .extension-cluster {
    position: relative;
    display: flex;
    align-items: center;
    /* Same 4px rhythm as the URL action buttons next to it. */
    gap: 4px;
    flex-shrink: 0;
  }

  /* Backwards fill, not both: once the entry has played the animation must stop applying, or
     it would outrank the fade-out of the next swap. */
  .extension-icon {
    position: relative;
    animation: cluster-icon-in 360ms var(--motion-ease-bounce) backwards;
    animation-delay: calc(var(--icon-index, 0) * 60ms);
    width: 20px;
    height: 20px;
    padding: 0;
    border: none;
    background: transparent;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-primary);
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-semibold);
    overflow: visible;
  }

  @keyframes cluster-icon-in {
    from {
      opacity: 0;
      transform: scale(0.55) translateY(3px);
    }
  }

  /* Discreet on an idle address bar; takes the neighbouring action buttons' exact surface once
     the bar wakes up, so the two never read as different kinds of control. */
  .extension-icon-face {
    position: relative;
    width: 20px;
    height: 20px;
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--text-primary) 8%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    transition:
      background-color var(--motion-duration-normal) ease,
      color var(--motion-duration-normal) ease,
      transform 160ms ease;
  }

  :global(.url-trigger:hover) .extension-icon-face,
  :global(.url-trigger:focus-within) .extension-icon-face {
    background: color-mix(
      in srgb,
      var(--text-primary) 18%,
      var(--bg-active)
    );
  }

  .extension-icon:hover .extension-icon-face {
    background: color-mix(in srgb, var(--accent) 14%, var(--bg-active));
    color: var(--accent);
  }

  .extension-icon:active .extension-icon-face {
    transform: scale(0.94);
  }

  .extension-menu-btn.active .extension-icon-face {
    background: color-mix(in srgb, var(--accent) 14%, var(--bg-active));
    color: var(--accent);
  }

  .extension-icon:focus-visible {
    outline: none;
  }

  .extension-icon:focus-visible .extension-icon-face {
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 46%, transparent);
  }

  .extension-icon.action-disabled .extension-icon-face {
    opacity: var(--disabled-opacity);
  }

  .ext-initial {
    position: absolute;
    pointer-events: none;
  }

  .ext-icon-image:not([hidden]) + .ext-initial {
    display: none;
  }

  .ext-icon-image {
    width: 15px;
    height: 15px;
    object-fit: contain;
    pointer-events: none;
    position: relative;
    z-index: 1;
  }

  /* Chrome's badge fits about four characters: longer text is cut at the icon's edge. */
  .badge {
    position: absolute;
    top: -4px;
    right: -4px;
    min-width: 13px;
    max-width: 28px;
    height: 13px;
    padding: 0 4px;
    overflow: hidden;
    white-space: nowrap;
    border-radius: var(--radius-chip);
    border: 1.5px solid color-mix(in srgb, var(--bg-primary) 88%, transparent);
    font-size: var(--font-size-3xs);
    font-weight: var(--font-weight-bold);
    color: var(--on-color);
    display: flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    pointer-events: none;
    z-index: 2;
  }

  .cluster-dot {
    position: absolute;
    top: -1px;
    right: -1px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent);
    border: 1.5px solid color-mix(in srgb, var(--bg-primary) 88%, transparent);
    pointer-events: none;
  }
</style>
