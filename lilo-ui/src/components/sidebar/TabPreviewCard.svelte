<!-- Floating hover preview for a sidebar tab row. Purely visual (pointer-events none, no
     interactive zone) except for a terminal waiting on a menu: then it offers the options, and
     takes clicks over the page. -->
<script lang="ts">
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { terminalActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltipTabURL } from "../../lib/bridge/coerceHelpers";
  import { clearTabPreview, getTabPreview, holdTabPreview } from "../../stores/tabPreview.svelte";
  import { tabUsageLabel } from "../../stores/tabMemory.svelte";

  const preview = $derived(getTabPreview());
  const terminal = $derived(preview?.terminal ?? null);
  const answerable = $derived(!!terminal?.choices.length);

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

  // Any scroll (sidebar tab list included) invalidates the anchor: hide instantly.
  $effect(() => {
    if (!preview) return;
    const hide = () => clearTabPreview();
    window.addEventListener("scroll", hide, true);
    return () => window.removeEventListener("scroll", hide, true);
  });

  const top = $derived(
    preview
      ? Math.max(
          8,
          Math.min(preview.anchor.top, window.innerHeight - cardHeight - 8),
        )
      : 0,
  );
</script>

{#if preview}
  <div
    class="tab-preview-card float-surface"
    class:terminal={!!terminal}
    class:answerable
    style={`left: ${preview.anchor.right + 8}px; top: ${top}px;`}
    bind:clientHeight={cardHeight}
    aria-hidden={!answerable}
    use:reportInteractiveZone={{ id: "tab-preview-card", active: answerable }}
    onmouseenter={holdTabPreview}
    onmouseleave={() => answerable && clearTabPreview()}
  >
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
