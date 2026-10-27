<script lang="ts">
  import { onDestroy } from "svelte";
  import { SvelteSet } from "svelte/reactivity";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { t } from "../../lib/i18n/state.svelte";
  import { getActiveSpaceId, getSpaces } from "../../stores/spaces.svelte";
  import type { TabState } from "../../stores/folders.svelte";
  import { getOpenTabs, tabDisplayTitle } from "../../stores/tabs.svelte";
  import {
    getTabShareRequest,
    getTabShareThumbnail,
    requestTabShareThumbnail,
    resolveTabShare,
  } from "../../stores/tabShare.svelte";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";

  interface Section {
    id: string;
    label: string;
    tabs: TabState[];
    collapsible: boolean;
  }

  const request = $derived(getTabShareRequest());
  let query = $state("");
  let selectedId = $state<string | null>(null);
  // Other Spaces open on demand: the current one is where the tab to share usually is.
  const expanded = new SvelteSet<string>();

  // Current space's tabs first, then the other spaces in sidebar order; only the tabs native can
  // resolve to a live engine, so a pick never fails silently.
  const spaceTabs = $derived.by(() => {
    if (!request) return [];
    const activeSpaceId = getActiveSpaceId();
    const spaces = getSpaces();
    return [
      ...spaces.filter((space) => space.id === activeSpaceId),
      ...spaces.filter((space) => space.id !== activeSpaceId),
    ].map((space) => ({
      space,
      tabs: getOpenTabs(space.id).filter((tab) => request.shareableTabIds.has(tab.id)),
    }));
  });

  const sections = $derived.by((): Section[] => {
    if (!request) return [];
    const needle = query.trim().toLowerCase();
    if (needle) {
      const tabs = spaceTabs
        .flatMap((entry) => entry.tabs)
        .filter((tab) => `${tabDisplayTitle(tab.title)} ${tab.url}`.toLowerCase().includes(needle));
      return tabs.length ? [{ id: "results", label: "", tabs, collapsible: false }] : [];
    }
    const byId = new Map(spaceTabs.flatMap((entry) => entry.tabs.map((tab) => [tab.id, tab] as const)));
    const suggested = request.suggestedTabIds.flatMap((id) => byId.get(id) ?? []);
    const suggestedIds = new Set(suggested.map((tab) => tab.id));
    const activeSpaceId = getActiveSpaceId();
    return [
      ...(suggested.length ? [{ id: "suggested", label: t("tabShare.suggested"), tabs: suggested, collapsible: false }] : []),
      ...spaceTabs
        .map(({ space, tabs }) => ({
          id: space.id,
          label: space.name,
          tabs: tabs.filter((tab) => !suggestedIds.has(tab.id)),
          collapsible: space.id !== activeSpaceId,
        }))
        .filter((section) => section.tabs.length > 0),
    ];
  });

  // What arrows, Enter and the Share button reach: collapsed Spaces hide their cards.
  const visibleTabs = $derived(
    sections.flatMap((section) => (section.collapsible && !expanded.has(section.id) ? [] : section.tabs)),
  );

  // The first card is picked by default, so Enter right away shares the likeliest tab.
  $effect(() => {
    if (!visibleTabs.some((tab) => tab.id === selectedId)) selectedId = visibleTabs[0]?.id ?? null;
  });

  $effect(() => {
    if (request) return;
    query = "";
    selectedId = null;
    expanded.clear();
  });

  // Present only when the page asked for sound.
  const audio = $derived(request?.audio ?? null);
  let systemAudioChoice = $state<boolean | null>(null);
  $effect(() => {
    if (!request) systemAudioChoice = null;
  });
  const systemAudioBlocked = $derived(audio?.system === "denied" || audio?.system === "unsupported");
  const systemAudioOn = $derived(!!audio && !systemAudioBlocked && (systemAudioChoice ?? audio.systemOn));
  const systemAudioNote = $derived(
    !audio || !request?.allowsSystem
      ? ""
      : systemAudioBlocked
        ? t(`tabShare.systemAudio.${audio.system}`)
        : systemAudioOn && audio.system === "undetermined"
          ? t("tabShare.systemAudio.undetermined")
          : "",
  );

  let panelEl = $state<HTMLDivElement>();
  let listEl = $state<HTMLDivElement>();

  // Snapshots only for cards scrolled into view: a long tab list costs nothing past its first rows.
  const visibility = $derived.by(() => {
    if (!listEl) return null;
    return new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const id = (entry.target as HTMLElement).dataset.shareTabId;
          if (entry.isIntersecting && id) requestTabShareThumbnail(id);
        }
      },
      { root: listEl, rootMargin: "80px" },
    );
  });
  $effect(() => {
    const observer = visibility;
    return () => observer?.disconnect();
  });

  function observe(node: HTMLElement) {
    visibility?.observe(node);
    return () => visibility?.unobserve(node);
  }

  function toggleSection(id: string) {
    if (!expanded.delete(id)) expanded.add(id);
  }

  // The nearest card in the arrow's direction, by on-screen position: rows differ in length
  // between sections, so an index step would land on the wrong card.
  function moveSelection(key: string) {
    if (!panelEl) return;
    const cards = [...panelEl.querySelectorAll<HTMLElement>("[data-share-tab-id]")];
    const current = cards.find((card) => card.dataset.shareTabId === selectedId);
    if (!current) return;
    const from = current.getBoundingClientRect();
    const [dx, dy] = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[key] ?? [0, 0];
    let best: HTMLElement | null = null;
    let bestScore = Infinity;
    for (const card of cards) {
      if (card === current) continue;
      const to = card.getBoundingClientRect();
      const along = (to.left - from.left) * dx + (to.top - from.top) * dy;
      if (along <= 1) continue;
      const across = dx ? Math.abs(to.top - from.top) : Math.abs(to.left - from.left);
      const score = along + across * 4;
      if (score < bestScore) {
        bestScore = score;
        best = card;
      }
    }
    if (!best) return;
    selectedId = best.dataset.shareTabId ?? selectedId;
    best.scrollIntoView({ block: "nearest" });
  }

  function share(tabId: string | null) {
    if (tabId) resolveTabShare("tab", tabId);
  }

  // A modal: Tab cycles through the picker's controls instead of reaching the sidebar behind it.
  // Capture phase, so Escape cancels the picker alone, not the panel or bar under it.
  function handleKeydown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      resolveTabShare("cancel");
      return;
    }
    if (e.key === "Enter" && !(e.target instanceof HTMLButtonElement)) {
      e.preventDefault();
      share(selectedId);
      return;
    }
    // Left and right stay with the search field's caret while it holds text.
    const inField = e.target instanceof HTMLInputElement && query !== "";
    if (e.key === "ArrowUp" || e.key === "ArrowDown" || ((e.key === "ArrowLeft" || e.key === "ArrowRight") && !inField)) {
      e.preventDefault();
      moveSelection(e.key);
      return;
    }
    if (e.key !== "Tab" || !panelEl) return;
    const controls = [...panelEl.querySelectorAll<HTMLElement>("input:not(:disabled), button:not(:disabled)")];
    if (controls.length === 0) return;
    e.preventDefault();
    const index = controls.indexOf(document.activeElement as HTMLElement);
    const step = e.shiftKey ? -1 : 1;
    const next = index < 0 ? (e.shiftKey ? controls.length - 1 : 0) : (index + step + controls.length) % controls.length;
    controls[next].focus();
  }

  function handleBackdropClick(e: MouseEvent) {
    if (e.target === e.currentTarget) {
      resolveTabShare("cancel");
    }
  }

  // Window teardown must not leave the page's getDisplayMedia promise hanging.
  onDestroy(() => resolveTabShare("cancel"));
</script>

<svelte:window onkeydowncapture={request ? handleKeydown : undefined} />

{#if request}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div
    class="tab-share-backdrop chrome-content-overlay-root"
    class:sidebar-hidden={!isSidebarVisible()}
    use:reportInteractiveZone={{ id: "tab-share-picker" }}
    onclick={handleBackdropClick}
  >
    <div
      class="tab-share-panel chrome-floating-surface"
      role="dialog"
      aria-modal="true"
      aria-label={t("tabShare.title", { origin: request.origin })}
      tabindex="-1"
      bind:this={panelEl}
    >
      <header class="tab-share-header">
        <div class="tab-share-heading">
          <h2 class="tab-share-title">
            {t("tabShare.title", { origin: request.origin })}
          </h2>
          <p class="tab-share-subtitle">{t("tabShare.pickTab")}</p>
        </div>
        <div class="tab-share-tools">
          <label class="tab-share-search">
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
              <circle cx="5.2" cy="5.2" r="3.7" stroke="currentColor" stroke-width="1.3" />
              <path d="M8 8l2.6 2.6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
            </svg>
            <input
              type="search"
              placeholder={t("tabShare.search")}
              aria-label={t("tabShare.search")}
              bind:value={query}
              {@attach (node) => node.focus()}
            />
          </label>
          {#if request.allowsSystem}
            <button class="tab-share-btn" onclick={() => resolveTabShare("system", undefined, systemAudioOn)}>
              <svg width="13" height="13" viewBox="0 0 14 14" fill="none" aria-hidden="true">
                <rect x="1.5" y="2" width="11" height="7.5" rx="1.3" stroke="currentColor" stroke-width="1.2" />
                <path d="M5 12h4M7 9.5V12" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
              </svg>
              {t("tabShare.shareSystem")}
            </button>
            {#if audio}
              <label class="tab-share-sound" class:disabled={systemAudioBlocked}>
                <input
                  type="checkbox"
                  checked={systemAudioOn}
                  disabled={systemAudioBlocked}
                  aria-describedby={systemAudioNote ? "tab-share-system-note" : undefined}
                  onchange={(event) => (systemAudioChoice = event.currentTarget.checked)}
                />
                {t("tabShare.shareAudio")}
              </label>
            {/if}
          {/if}
        </div>
        {#if systemAudioNote}
          <p class="tab-share-note" id="tab-share-system-note">{systemAudioNote}</p>
        {/if}
      </header>

      <div class="tab-share-list" bind:this={listEl}>
        {#each sections as section (section.id)}
          {@const open = !section.collapsible || expanded.has(section.id)}
          <section class="tab-share-section">
            {#if section.collapsible}
              <button class="tab-share-group toggle" aria-expanded={open} onclick={() => toggleSection(section.id)}>
                <svg class="chevron" class:open width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
                  <path d="M3.5 2l3 3-3 3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
                </svg>
                <span>{section.label}</span>
                <span class="count">{section.tabs.length}</span>
              </button>
            {:else if section.label}
              <h3 class="tab-share-group">{section.label}</h3>
            {/if}
            {#if open}
              <div class="tab-share-grid">
                {#each section.tabs as tab (tab.id)}
                  {@const thumbnail = getTabShareThumbnail(tab.id)}
                  <button
                    class="tab-share-card"
                    class:selected={tab.id === selectedId}
                    aria-pressed={tab.id === selectedId}
                    data-share-tab-id={tab.id}
                    {@attach observe}
                    onclick={() => (selectedId = tab.id)}
                    ondblclick={() => share(tab.id)}
                  >
                    <span class="tab-share-thumb">
                      {#if thumbnail}
                        <img src={thumbnail} alt="" draggable="false" />
                      {:else}
                        <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={24} radius={6} />
                      {/if}
                      {#if tab.isAudioPlaying}
                        <span class="tab-share-audio" aria-label={t("tabShare.playing")}>
                          <svg width="10" height="10" viewBox="0 0 12 12" fill="none" aria-hidden="true">
                            <path d="M2 4.5H3.5L6.5 2V10L3.5 7.5H2V4.5Z" fill="currentColor" />
                            <path d="M8 4.5C8.83 5 8.83 7 8 7.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
                          </svg>
                        </span>
                      {/if}
                    </span>
                    <span class="tab-share-meta">
                      <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={14} radius={4} />
                      <span class="tab-share-card-title">{tabDisplayTitle(tab.title)}</span>
                    </span>
                  </button>
                {/each}
              </div>
            {/if}
          </section>
        {:else}
          <p class="tab-share-empty">{t(query.trim() ? "tabShare.noMatch" : "tabShare.noTabs")}</p>
        {/each}
      </div>

      <footer class="tab-share-footer">
        <span class="tab-share-hint">{t("tabShare.keyHint")}</span>
        <div class="tab-share-actions">
          <button class="tab-share-btn" onclick={() => resolveTabShare("cancel")}>
            {t("common.cancel")}
          </button>
          <button class="tab-share-btn primary" disabled={!selectedId} onclick={() => share(selectedId)}>
            {t("tabShare.share")}
          </button>
        </div>
      </footer>
    </div>
  </div>
{/if}

<style>
  .tab-share-backdrop {
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: clamp(18px, 6vh, 64px) 16px 16px;
    z-index: 61;
    pointer-events: auto;
    overflow: hidden;
    background: var(--chrome-overlay-backdrop-tint);
    backdrop-filter: blur(var(--chrome-overlay-backdrop-blur)) saturate(1.04);
  }

  .tab-share-panel {
    width: min(680px, 100%);
    max-height: calc(100% - 24px);
    display: flex;
    flex-direction: column;
    overflow: hidden;
    color: var(--text-primary);
    outline: none;
    animation: tab-share-rise 340ms var(--motion-ease-bounce);
  }

  .tab-share-header {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px 18px 12px;
  }

  .tab-share-title {
    margin: 0;
    font-size: var(--font-size-lg);
    font-weight: var(--font-weight-semibold);
    line-height: 1.3;
    overflow-wrap: break-word;
  }

  .tab-share-subtitle {
    margin: 2px 0 0;
    font-size: var(--font-size-sm);
    color: var(--text-muted);
  }

  .tab-share-tools {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }

  .tab-share-search {
    flex: 1;
    min-width: 160px;
    display: flex;
    align-items: center;
    gap: 6px;
    height: 28px;
    padding: 0 9px;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-10);
    color: var(--text-muted);
  }

  .tab-share-search:focus-within {
    outline: var(--focus-outline);
  }

  .tab-share-search input {
    flex: 1;
    min-width: 0;
    border: none;
    outline: none;
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
  }

  .tab-share-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 2px 18px 14px;
    overflow-y: auto;
    flex: 1 1 auto;
    min-height: 0;
  }

  .tab-share-section {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .tab-share-group {
    display: flex;
    align-items: center;
    gap: 6px;
    margin: 0;
    padding: 2px 0;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.03em;
    text-transform: uppercase;
    color: var(--text-muted);
  }

  .tab-share-group.toggle {
    border: none;
    background: transparent;
    font-family: inherit;
    text-align: left;
    cursor: pointer;
    border-radius: var(--radius-xs);
  }

  .tab-share-group.toggle:hover {
    color: var(--text-primary);
  }

  .tab-share-group .count {
    font-weight: var(--font-weight-medium);
    opacity: 0.7;
  }

  .chevron {
    transition: transform var(--transition-fast);
  }

  .chevron.open {
    transform: rotate(90deg);
  }

  .tab-share-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
    gap: 8px;
  }

  .tab-share-card {
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 0;
    padding: 5px;
    border: 2px solid transparent;
    border-radius: var(--radius-md);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    text-align: left;
    cursor: pointer;
    transition: background var(--transition-fast), border-color var(--transition-fast);
  }

  .tab-share-card:hover {
    background: var(--bg-hover);
  }

  .tab-share-card.selected {
    border-color: var(--accent);
    background: var(--text-primary-tint-10);
  }

  .tab-share-card:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .tab-share-thumb {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    aspect-ratio: 16 / 10;
    max-width: 100%;
    overflow: hidden;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-10);
  }

  .tab-share-thumb img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: top;
  }

  .tab-share-audio {
    position: absolute;
    right: 5px;
    bottom: 5px;
    display: flex;
    padding: 3px 5px;
    border-radius: var(--radius-chip);
    background: var(--accent);
    color: var(--accent-text);
  }

  .tab-share-meta {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    padding: 0 2px;
  }

  .tab-share-card-title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-sm);
  }

  .tab-share-empty {
    margin: 0;
    padding: 24px 10px;
    font-size: var(--font-size-md);
    color: var(--text-muted);
    text-align: center;
  }

  .tab-share-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 10px 12px 10px 18px;
    border-top: 1px solid var(--separator);
  }

  .tab-share-hint {
    font-size: var(--font-size-xs);
    color: var(--text-muted);
  }

  .tab-share-sound {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--font-size-sm);
    color: var(--text-primary);
    cursor: pointer;
  }

  .tab-share-sound input {
    margin: 0;
    accent-color: var(--accent);
  }

  .tab-share-sound.disabled {
    color: var(--text-muted);
    cursor: default;
  }

  .tab-share-note {
    margin: 0;
    font-size: var(--font-size-xs);
    color: var(--text-muted);
  }

  .tab-share-actions {
    display: flex;
    gap: 8px;
    margin-left: auto;
  }

  .tab-share-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    font-family: inherit;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg-primary);
    color: var(--text-primary);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .tab-share-btn:hover {
    background: var(--bg-hover);
  }

  .tab-share-btn.primary {
    border-color: var(--accent);
    background: var(--accent);
    color: var(--accent-text);
  }

  .tab-share-btn.primary:hover {
    background: var(--accent-hover);
  }

  .tab-share-btn:disabled {
    opacity: 0.5;
    cursor: default;
  }

  .tab-share-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  @keyframes tab-share-rise {
    from {
      opacity: 0;
      transform: translateY(-6px) scale(0.985);
    }

    to {
      opacity: 1;
      transform: translateY(0) scale(1);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .tab-share-panel {
      animation: none;
    }

    .chevron {
      transition: none;
    }
  }
</style>
