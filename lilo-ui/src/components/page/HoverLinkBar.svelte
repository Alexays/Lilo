<script lang="ts">
  import { fade, fly } from "svelte/transition";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { cubicOut } from "svelte/easing";
  import { springEase } from "../../lib/motion/spring";
  import { on } from "../../lib/bridge";
  import { getActiveTabId } from "../../stores/tabs.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { t } from "../../lib/i18n/state.svelte";

  let href = $state("");
  let cmdDown = $state(false);

  // Swift pushes the hovered content link (empty string when none). Non-interactive pill.
  $effect(() =>
    on("hoveredLinkChanged", (data) => {
      href = data.href ?? "";
    }),
  );
  // The native hover event only fires over web content, so a tab/space switch clears the link. Read through $derived:
  // a direct read would also clear it on every tab patch, and Swift never resends an unchanged link.
  const activeTabId = $derived(getActiveTabId());
  const activeSpaceId = $derived(getActiveSpaceId());
  $effect(() => {
    void activeTabId;
    void activeSpaceId;
    href = "";
  });
  // Command-key state (from the native NSEvent monitor) flags "open in background tab".
  $effect(() =>
    on("commandKeyChanged", (data) => {
      cmdDown = data.down ?? false;
    }),
  );

  // Strip the scheme + www and split host from the rest so the domain reads crisp
  // while the path stays muted.
  const parts = $derived.by<{ host: string; rest: string } | null>(() => {
    if (!href) return null;
    try {
      const url = new URL(href);
      if (url.protocol === "http:" || url.protocol === "https:") {
        const host = url.host.replace(/^www\./, "");
        const path = url.pathname === "/" ? "" : url.pathname;
        return { host, rest: path + url.search + url.hash };
      }
    } catch {
      // fall through for non-URL hrefs (mailto:, tel:, ...)
    }
    return { host: href, rest: "" };
  });
</script>

{#if parts}
  <div
    class="hover-link-bar"
    in:fly={{ y: 6, duration: prefersReducedMotion() ? 0 : 280, delay: 50, easing: springEase }}
    out:fade={{ duration: prefersReducedMotion() ? 0 : 220, delay: 60, easing: cubicOut }}
  >
    <span class="host">{parts.host}</span><span class="rest">{parts.rest}</span>
    {#if cmdDown}<span class="hint">↗ {t("hoverLinkBar.backgroundTab")}</span>{/if}
  </div>
{/if}

<style>
  .hover-link-bar {
    position: fixed;
    bottom: calc(var(--chrome-content-bottom) + var(--chrome-overlay-edge-gap));
    left: calc(var(--chrome-content-left-visible) + var(--chrome-overlay-edge-gap));
    max-width: 60vw;
    display: flex;
    align-items: baseline;
    padding: 4px 12px;
    font-size: var(--font-size-sm);
    line-height: 1.4;
    letter-spacing: 0.1px;
    background: var(--chrome-floating-surface);
    border: 1px solid var(--chrome-overlay-border);
    border-radius: var(--radius-lg);
    box-shadow: var(--chrome-floating-shadow);
    white-space: nowrap;
    overflow: hidden;
    pointer-events: none;
    z-index: 800;
  }

  .host {
    flex: none;
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  .rest {
    flex: 0 1 auto;
    min-width: 0;
    color: var(--text-muted);
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .hint {
    flex: none;
    margin-left: 10px;
    padding-left: 10px;
    border-left: 1px solid var(--chrome-overlay-border);
    color: var(--accent);
    font-weight: var(--font-weight-medium);
  }
</style>
