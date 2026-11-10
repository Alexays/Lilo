<!-- Floating hover preview for a sidebar tab row. Purely visual (pointer-events none, no
     interactive zone) except for a terminal waiting on a menu: then it offers the options, and
     takes clicks over the page. A pinned tab or a favorite glances instead: its live page, the
     host's own view laid over the card's page slot, in a card the user can resize. -->
<script lang="ts">
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { tabActions, terminalActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltipTabURL } from "../../lib/bridge/coerceHelpers";
  import { clearTabPreview, getTabPreview, holdTabPreview, leaveTabPreview } from "../../stores/tabPreview.svelte";
  import { tabUsageLabel } from "../../stores/tabMemory.svelte";
  import { getTabPosition } from "../../stores/tabLayout.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import Icon from "../ui/Icon.svelte";
  import { clampGlanceSize, formatGlanceSize, GLANCE_SIZE_SETTING, parseGlanceSize, type GlanceSize } from "./tabGlanceModel";

  const preview = $derived(getTabPreview());
  const terminal = $derived(preview?.terminal ?? null);
  const answerable = $derived(!!terminal?.choices.length);
  const glance = $derived(!!preview?.glance);

  function answer(tabId: string, key: string): void {
    terminalActions.answer(tabId, key);
    clearTabPreview();
  }

  function open(tabId: string): void {
    terminalActions.reveal(tabId);
    clearTabPreview();
  }
  // The row hover already drives the shared tabMemory live refresh; the card only reads it.
  const usage = $derived(preview ? tabUsageLabel(preview.tabId) : "");
  const displayURL = $derived(tooltipTabURL(preview?.url));
  let cardHeight = $state(0);
  let cardWidth = $state(0);

  // Any scroll (sidebar tab list included) invalidates the anchor: hide instantly.
  $effect(() => {
    if (!preview) return;
    const hide = () => clearTabPreview();
    window.addEventListener("scroll", hide, true);
    return () => window.removeEventListener("scroll", hide, true);
  });

  const clamp = (value: number, size: number, room: number) => Math.max(8, Math.min(value, room - size - 8));

  // A glance clears the whole sidebar, not just the row: a favorite tile sits mid-sidebar.
  const sidebarRect = () => document.querySelector(".sidebar-viewport")?.getBoundingClientRect();

  let dragSize = $state<GlanceSize | null>(null);
  const glanceSize = $derived.by(() => {
    const room = { width: window.innerWidth - (sidebarRect()?.width ?? 0) - 24, height: window.innerHeight - 16 };
    return clampGlanceSize(dragSize ?? parseGlanceSize(getSetting(GLANCE_SIZE_SETTING, "")), room);
  });
  // The card grows away from the tabs: its handles sit on the far edges.
  const growsLeft = $derived(getTabPosition() === "right");
  const growsUp = $derived(getTabPosition() === "bottom");

  function startResize(event: PointerEvent, axes: { x: boolean; y: boolean }): void {
    event.preventDefault();
    const handle = event.currentTarget as HTMLElement;
    handle.setPointerCapture(event.pointerId);
    const start = { x: event.clientX, y: event.clientY, size: glanceSize };
    const move = (e: PointerEvent) => {
      holdTabPreview();
      dragSize = {
        width: start.size.width + (axes.x ? (e.clientX - start.x) * (growsLeft ? -1 : 1) : 0),
        height: start.size.height + (axes.y ? (e.clientY - start.y) * (growsUp ? -1 : 1) : 0),
      };
    };
    const end = () => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", end);
      handle.removeEventListener("pointercancel", end);
      setSetting(GLANCE_SIZE_SETTING, formatGlanceSize(glanceSize));
      dragSize = null;
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", end);
    handle.addEventListener("pointercancel", end);
  }

  function openGlancedTab(tabId: string): void {
    clearTabPreview();
    optimisticallyActivateTab(tabId);
    tabActions.switchTo(tabId);
  }

  // Beside a sidebar row, under a top strip's pill, above a bottom dock's.
  const placement = $derived.by(() => {
    if (!preview) return { left: 0, top: 0 };
    const { anchor } = preview;
    switch (getTabPosition()) {
      case "right": {
        const edge = glance ? Math.min(anchor.left, sidebarRect()?.left ?? anchor.left) : anchor.left;
        return { left: edge - 8 - cardWidth, top: clamp(anchor.top, cardHeight, window.innerHeight) };
      }
      case "top":
      case "bottom": {
        // Clear of the strip itself, toward the page.
        const strip = document.querySelector(".tab-strip")?.getBoundingClientRect() ?? anchor;
        const left = clamp(anchor.left, cardWidth, window.innerWidth);
        return getTabPosition() === "top" ? { left, top: strip.bottom + 6 } : { left, top: strip.top - 8 - cardHeight };
      }
      default: {
        const edge = glance ? Math.max(anchor.right, sidebarRect()?.right ?? anchor.right) : anchor.right;
        return { left: edge + 8, top: clamp(anchor.top, cardHeight, window.innerHeight) };
      }
    }
  });
</script>

{#if preview}
  <div
    class="tab-preview-card float-surface"
    class:terminal={!!terminal}
    class:answerable
    class:glance
    class:grows-left={growsLeft}
    class:grows-up={growsUp}
    class:resizing={!!dragSize}
    style={`left: ${placement.left}px; top: ${placement.top}px;${glance ? ` width: ${glanceSize.width}px; height: ${glanceSize.height}px;` : ""}`}
    bind:clientHeight={cardHeight}
    bind:clientWidth={cardWidth}
    aria-hidden={!answerable && !glance}
    use:reportInteractiveZone={{ id: "tab-preview-card", active: answerable || glance }}
    onmouseenter={holdTabPreview}
    onpointermove={() => glance && holdTabPreview()}
    onmouseleave={() => (glance ? leaveTabPreview() : answerable && clearTabPreview())}
  >
    {#if glance}
      <div class="tab-glance-header">
        {#if preview.favicon}
          <img class="tab-preview-favicon" src={preview.favicon} alt="" draggable="false" />
        {/if}
        <span class="tab-glance-title">{preview.title}</span>
        <button type="button" class="tab-glance-button" aria-label={t("common.open")} title={t("common.open")} onclick={() => openGlancedTab(preview.tabId)}>
          <Icon name="external" size={13} />
        </button>
        <button type="button" class="tab-glance-button" aria-label={t("common.close")} title={t("common.close")} onclick={() => clearTabPreview()}>
          <Icon name="close" size={13} />
        </button>
      </div>
      <!-- The host lays the tab's page over this slot, so it never shows through. -->
      <div class="tab-glance-page" use:reportInteractiveZone={{ id: "tab-glance-page" }}></div>
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div class="tab-glance-resize x" onpointerdown={(e) => startResize(e, { x: true, y: false })}></div>
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div class="tab-glance-resize y" onpointerdown={(e) => startResize(e, { x: false, y: true })}></div>
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div class="tab-glance-resize xy" onpointerdown={(e) => startResize(e, { x: true, y: true })}></div>
    {:else}
    <div class="tab-preview-header" class:has-favicon={!!preview.favicon}>
      <div class="tab-preview-title-row">
        {#if preview.favicon}
          <img class="tab-preview-favicon" src={preview.favicon} alt="" draggable="false" />
        {/if}
        <span class="tab-preview-title">{preview.title}</span>
      </div>
      {#if displayURL || usage}
        <div class="tab-preview-meta">
          {#if displayURL}<span class="tab-preview-url">{displayURL}</span>{/if}
          {#if usage}<span class="tab-preview-memory">{usage}</span>{/if}
        </div>
      {/if}
    </div>
    {#if terminal}
      {@const screen = answerable ? terminal.question : terminal.lines.join("\n")}
      {#if screen}
        <pre class="tab-preview-screen">{screen}</pre>
      {/if}
      {#if answerable}
        <div class="tab-preview-choices">
          {#each terminal.choices as choice (choice.key)}
            <button type="button" class="choice" onclick={() => answer(preview.tabId, choice.key)}>
              <span class="key">{choice.key}</span><span class="label">{choice.label}</span>
            </button>
          {/each}
          <button type="button" class="open" onclick={() => open(preview.tabId)}>{t("tabItem.previewOpen")}</button>
        </div>
      {/if}
    {:else}
      <img class="tab-preview-image" src={preview.image} alt="" draggable="false" />
    {/if}
    {/if}
  </div>
{/if}

<style>
  .tab-preview-card {
    position: fixed;
    width: 260px;
    padding: 10px;
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    gap: 8px;
    border-radius: var(--float-radius-card);
    pointer-events: none;
    z-index: var(--z-card);
    animation: tab-preview-in 160ms var(--motion-ease-spring) both;
  }

  .tab-preview-card.terminal {
    width: 320px;
  }

  .tab-preview-card.answerable {
    pointer-events: auto;
  }

  .tab-preview-header {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
  }

  .tab-preview-title-row {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    min-width: 0;
  }

  .tab-preview-favicon {
    flex: none;
    width: 14px;
    height: 14px;
    margin-top: 1px;
    border-radius: var(--radius-xs);
    object-fit: cover;
  }

  /* The card is the only hover surface naming the tab once it replaces the tooltip, so the
     title wraps in full instead of being clipped. */
  .tab-preview-title {
    min-width: 0;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    line-height: 1.35;
    overflow-wrap: anywhere;
  }

  /* The address gives way first: the memory stays whole. */
  .tab-preview-meta {
    display: flex;
    gap: 4px;
    min-width: 0;
    font-size: var(--font-size-xs);
    color: var(--text-muted);
    white-space: nowrap;
  }

  .has-favicon .tab-preview-meta {
    padding-left: 22px;
  }

  .tab-preview-url {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .tab-preview-memory {
    flex: none;
    font-variant-numeric: tabular-nums;
  }

  .tab-preview-url + .tab-preview-memory::before {
    content: "\00B7  ";
  }

  .tab-preview-image {
    width: 100%;
    height: auto;
    border-radius: var(--radius-sm);
    display: block;
  }

  .tab-preview-screen {
    margin: 0;
    padding: 8px;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    font: var(--font-size-xs)/1.45 ui-monospace, "SF Mono", Menlo, monospace;
    color: var(--text-primary);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    max-height: 9.5lh;
    overflow: hidden;
  }

  .tab-preview-choices {
    display: grid;
    gap: 2px;
  }

  .tab-preview-choices button {
    display: flex;
    align-items: baseline;
    gap: 8px;
    min-width: 0;
    min-height: 28px;
    padding: 6px 8px;
    box-sizing: border-box;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
    cursor: pointer;
  }

  .tab-preview-choices button:hover,
  .tab-preview-choices button:focus-visible {
    background: var(--bg-hover);
    outline: none;
  }

  .tab-preview-choices .key {
    flex: none;
    font-variant-numeric: tabular-nums;
    color: var(--text-muted);
  }

  .tab-preview-choices .label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .tab-preview-choices .open {
    color: var(--text-muted);
  }

  .tab-preview-card.glance {
    padding: 0 6px 6px;
    gap: 0;
    pointer-events: auto;
  }

  .tab-glance-header {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    height: 32px;
    padding-left: 4px;
    flex: none;
  }

  .tab-glance-title {
    flex: 1;
    min-width: 0;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .tab-glance-header .tab-preview-favicon {
    margin-top: 0;
  }

  .tab-glance-button {
    flex: none;
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
  }

  .tab-glance-button:hover,
  .tab-glance-button:focus-visible {
    background: var(--bg-hover);
    color: var(--text-primary);
    outline: none;
  }

  .tab-glance-page {
    flex: 1;
    min-height: 0;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
  }

  /* On the card's far edges, in its margin around the page, which the host's view leaves to the chrome. */
  .tab-glance-resize {
    position: absolute;
  }

  .tab-glance-resize.x {
    top: 0;
    bottom: 12px;
    right: 0;
    width: 6px;
    cursor: ew-resize;
  }

  .tab-glance-resize.y {
    left: 0;
    right: 12px;
    bottom: 0;
    height: 6px;
    cursor: ns-resize;
  }

  .tab-glance-resize.xy {
    right: 0;
    bottom: 0;
    width: 12px;
    height: 12px;
    cursor: nwse-resize;
  }

  .grows-left .tab-glance-resize.x,
  .grows-left .tab-glance-resize.xy {
    right: auto;
    left: 0;
  }

  .grows-left .tab-glance-resize.y {
    left: 12px;
    right: 0;
  }

  .grows-up .tab-glance-resize.y,
  .grows-up .tab-glance-resize.xy {
    bottom: auto;
    top: 0;
  }

  .grows-up .tab-glance-resize.x {
    top: 12px;
    bottom: 0;
  }

  .grows-left .tab-glance-resize.xy,
  .grows-up .tab-glance-resize.xy {
    cursor: nesw-resize;
  }

  .grows-left.grows-up .tab-glance-resize.xy {
    cursor: nwse-resize;
  }

  /* A drag follows the pointer, never the entrance animation. */
  .tab-preview-card.resizing {
    animation: none;
  }

  @keyframes tab-preview-in {
    from {
      opacity: 0;
      transform: translateX(-4px);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .tab-preview-card {
      animation: none;
    }
  }
</style>
