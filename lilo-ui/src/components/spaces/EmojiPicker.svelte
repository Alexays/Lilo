<script lang="ts">
  import { untrack } from "svelte";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import { ENGLISH_EMOJI, SKIN_TONES, emojiName, loadEmojiCatalog, searchEmoji, withTone } from "./emojiPickerModel";

  interface Props {
    selected: string;
    onpick: (emoji: string) => void;
    onclose: () => void;
  }

  let { selected, onpick, onclose }: Props = $props();

  // Rows share one height so the visible slice is plain arithmetic; a few extra hide the scroll edge.
  const ROW_HEIGHT = 32;
  const CELL_WIDTH = 32;
  const OVERSCAN = 3;

  const CATEGORY_KEYS = [
    "emojiSmileys",
    "emojiPeople",
    "emojiAnimals",
    "emojiFood",
    "emojiActivities",
    "emojiTravel",
    "emojiObjects",
    "emojiSymbols",
    "emojiFlags",
  ];
  const TONE_KEYS = [
    "skinToneDefault",
    "skinToneLight",
    "skinToneMediumLight",
    "skinToneMedium",
    "skinToneMediumDark",
    "skinToneDark",
  ];

  type Section = { key: string; start: number; end: number };
  type Row = { section: number; header: string } | { section: number; start: number; end: number };

  let query = $state("");
  let scrollTop = $state(0);
  let viewport = $state({ width: 0, height: 0 });
  let active = $state(0);
  let tonesOpen = $state(false);
  let gridEl: HTMLDivElement | undefined = $state();
  let root: HTMLDivElement | undefined = $state();
  // Raw: nothing mutates the entries, and a deep proxy over 1,900 of them would cost every read.
  let catalog = $state.raw(ENGLISH_EMOJI);

  // English until the locale's names load, which only changes labels: the glyphs stay where they are.
  $effect(() => {
    const locale = getLocale();
    loadEmojiCatalog(locale).then(
      (loaded) => {
        if (getLocale() === locale) catalog = loaded;
      },
      (error) => console.error(`Could not load the ${locale} emoji names`, error),
    );
  });

  const toneIndex = $derived(Number(getSetting("emojiSkinTone", "0")) || 0);
  const tone = $derived(SKIN_TONES[toneIndex] ?? "");
  const recent = $derived(getSetting("emojiRecent", "").split(" ").filter(Boolean));
  // Zero until the grid is measured: nothing is laid out for a width it does not have yet.
  const columns = $derived(Math.floor(viewport.width / CELL_WIDTH));
  // Without a query the sections are exactly these, in this order.
  const tabs = $derived(recent.length > 0 ? ["emojiRecent", ...CATEGORY_KEYS] : CATEGORY_KEYS);

  // The flat list the grid shows and the keyboard walks, cut into sections.
  const layout = $derived.by(() => {
    const items: string[] = [];
    const sections: Section[] = [];
    const rows: Row[] = [];
    if (columns === 0) return { items, sections, rows, rowOf: new Int32Array(0) };
    const add = (key: string, emoji: string[]) => {
      if (emoji.length === 0) return;
      sections.push({ key, start: items.length, end: items.length + emoji.length });
      items.push(...emoji);
    };
    if (query.trim()) {
      add("results", searchEmoji(catalog, query).map((entry) => withTone(entry, tone)));
    } else {
      add("emojiRecent", recent);
      catalog.categories.forEach((category, index) => add(CATEGORY_KEYS[index], category.map((entry) => withTone(entry, tone))));
    }
    const rowOf = new Int32Array(items.length);
    sections.forEach((section, index) => {
      if (section.key !== "results") rows.push({ section: index, header: t(`spaceEditor.${section.key}`) });
      for (let start = section.start; start < section.end; start += columns) {
        const end = Math.min(start + columns, section.end);
        rowOf.fill(rows.length, start, end);
        rows.push({ section: index, start, end });
      }
    });
    return { items, sections, rows, rowOf };
  });

  const firstRow = $derived(Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN));
  const lastRow = $derived(Math.ceil((scrollTop + viewport.height) / ROW_HEIGHT) + OVERSCAN);
  const visibleRows = $derived(layout.rows.slice(firstRow, lastRow).map((row, offset) => ({ row, index: firstRow + offset })));
  // The tab of the section under the top edge; a header just scrolled past still counts as its section.
  const currentSection = $derived(layout.rows[Math.floor(scrollTop / ROW_HEIGHT) + 1]?.section ?? 0);
  const currentKey = $derived(layout.sections[currentSection]?.key);

  // A new query starts over from its first result, or from the section of the tab that cleared it.
  let requestedSection = 0;
  $effect(() => {
    void query;
    untrack(() => revealSection(requestedSection));
    requestedSection = 0;
  });

  function trackViewport(node: HTMLElement) {
    viewport = { width: node.clientWidth, height: node.clientHeight };
    const observer = new ResizeObserver(([entry]) => {
      viewport = { width: entry.contentRect.width, height: entry.contentRect.height };
    });
    observer.observe(node);
    return () => observer.disconnect();
  }

  function scrollToRow(row: number) {
    if (!gridEl) return;
    const top = row * ROW_HEIGHT;
    if (top < gridEl.scrollTop) gridEl.scrollTop = top;
    else if (top + ROW_HEIGHT > gridEl.scrollTop + gridEl.clientHeight) gridEl.scrollTop = top + ROW_HEIGHT - gridEl.clientHeight;
  }

  function moveTo(index: number) {
    active = Math.max(0, Math.min(index, layout.items.length - 1));
    const row = layout.rowOf[active];
    // Keep the section header in view when the walk reaches a section's first row.
    scrollToRow(layout.rows[row - 1] && "header" in layout.rows[row - 1] ? row - 1 : row);
    scrollToRow(row);
  }

  // Up and down keep the column, landing on the nearest emoji of a shorter row.
  function moveVertically(step: 1 | -1): boolean {
    const { rows, rowOf } = layout;
    const from = rows[rowOf[active]];
    if (!from || !("start" in from)) return false;
    let target = rowOf[active] + step;
    while (rows[target] && !("start" in rows[target])) target += step;
    const to = rows[target];
    if (!to || !("start" in to)) return false;
    moveTo(Math.min(to.start + active - from.start, to.end - 1));
    return true;
  }

  // Scrolls the section's header to the top and walks on from its first emoji.
  function revealSection(index: number) {
    const start = layout.sections[index]?.start ?? 0;
    active = start;
    if (gridEl) gridEl.scrollTop = Math.max(0, (layout.rowOf[start] ?? 0) - 1) * ROW_HEIGHT;
  }

  // Under a query the grid shows results only: the sections come back once the query is cleared.
  function showSection(index: number) {
    if (!query) return revealSection(index);
    requestedSection = index;
    query = "";
  }

  function pick(emoji: string | undefined) {
    if (emoji) onpick(emoji);
  }

  function chooseTone(index: number) {
    setSetting("emojiSkinTone", String(index));
    tonesOpen = false;
    root?.querySelector<HTMLElement>(".tone-button")?.focus();
  }

  function handleGridKeydown(event: KeyboardEvent) {
    const moves: Record<string, () => boolean | void> = {
      ArrowRight: () => moveTo(active + 1),
      ArrowLeft: () => moveTo(active - 1),
      ArrowDown: () => moveVertically(1),
      ArrowUp: () => moveVertically(-1) || root?.querySelector<HTMLElement>(".ui-search-field input")?.focus(),
      Home: () => moveTo(0),
      End: () => moveTo(layout.items.length - 1),
      Enter: () => pick(layout.items[active]),
      " ": () => pick(layout.items[active]),
    };
    const move = moves[event.key];
    if (move) {
      event.preventDefault();
      move();
    } else if (event.key.length === 1 && !event.metaKey && !event.ctrlKey) {
      // Typing from the grid goes on with the search, as in the system picker.
      root?.querySelector<HTMLElement>(".ui-search-field input")?.focus();
    }
  }

  function handleTabsKeydown(event: KeyboardEvent) {
    if (event.key !== "ArrowRight" && event.key !== "ArrowLeft") return;
    event.preventDefault();
    const tabs = [...(event.currentTarget as HTMLElement).querySelectorAll<HTMLElement>("[role=tab]")];
    const at = tabs.indexOf(document.activeElement as HTMLElement);
    const next = tabs[(at + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length];
    next?.focus();
    next?.click();
  }

  function handleKeydown(event: KeyboardEvent) {
    const inSearch = event.target instanceof HTMLInputElement;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      if (tonesOpen) tonesOpen = false;
      else onclose();
    } else if (inSearch && event.key === "ArrowDown") {
      event.preventDefault();
      gridEl?.focus();
      moveTo(active);
    } else if (inSearch && event.key === "Enter" && !event.metaKey) {
      event.preventDefault();
      event.stopPropagation();
      pick(layout.items[active]);
    }
  }
</script>

{#snippet categoryIcon(key: string)}
  <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    {#if key === "emojiRecent"}
      <circle cx="8" cy="8" r="6" /><path d="M8 4.8V8l2.2 1.5" />
    {:else if key === "emojiSmileys"}
      <circle cx="8" cy="8" r="6" /><path d="M5.7 9.5c.6.9 1.4 1.3 2.3 1.3s1.7-.4 2.3-1.3M6 6.4v.5M10 6.4v.5" />
    {:else if key === "emojiPeople"}
      <circle cx="8" cy="5.3" r="2.6" /><path d="M3.3 13.6c.6-2.5 2.4-3.9 4.7-3.9s4.1 1.4 4.7 3.9" />
    {:else if key === "emojiAnimals"}
      <path d="M3.2 12.8C3.2 6.6 6.8 3.2 12.8 3.2c0 6-3.4 9.6-9.6 9.6zM3.2 12.8l5.4-5.4" />
    {:else if key === "emojiFood"}
      <path d="M3.2 6.2h7.4v3.6a3.2 3.2 0 0 1-3.2 3.2h-1a3.2 3.2 0 0 1-3.2-3.2zM10.6 7.2h.9a1.6 1.6 0 0 1 0 3.2h-1.1M5.6 2.6v1.6M8.2 2.6v1.6" />
    {:else if key === "emojiActivities"}
      <circle cx="8" cy="8" r="6" /><path d="M2 8h12M8 2c-2.2 1.6-3.2 3.6-3.2 6s1 4.4 3.2 6M8 2c2.2 1.6 3.2 3.6 3.2 6s-1 4.4-3.2 6" />
    {:else if key === "emojiTravel"}
      <path d="M3.9 8l1.2-2.8a1 1 0 0 1 .9-.6h4a1 1 0 0 1 .9.6L12.1 8" /><rect x="2.4" y="8" width="11.2" height="3.4" rx="1.1" /><path d="M4.4 11.4v1.4M11.6 11.4v1.4" />
    {:else if key === "emojiObjects"}
      <path d="M6.2 13.8h3.6M5.4 10.4a4.3 4.3 0 1 1 5.2 0c-.5.4-.8 1-.8 1.6H6.2c0-.6-.3-1.2-.8-1.6z" />
    {:else if key === "emojiSymbols"}
      <path d="M6.4 2.8 5.2 13.2M10.8 2.8 9.6 13.2M3.2 6h10M2.8 10h10" />
    {:else}
      <path d="M4 14V2.6M4 3.2c1.9-1 3.4-.3 4.9.4s2.8 1 4.1.3v6c-1.3.7-2.6.4-4.1-.3S5.9 8.2 4 9.2" />
    {/if}
  </svg>
{/snippet}

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="emoji-picker" bind:this={root} onkeydown={handleKeydown} {@attach (node) => node.querySelector("input")?.focus()}>
  <div class="picker-search">
    <UiSearchField value={query} onchange={(value) => (query = value)} placeholder={t("spaceEditor.searchEmoji")} ariaLabel={t("spaceEditor.searchEmoji")} />
    <button
      class="tone-button"
      class:open={tonesOpen}
      aria-label={t("spaceEditor.skinTone")}
      aria-expanded={tonesOpen}
      title={t("spaceEditor.skinTone")}
      onclick={() => (tonesOpen = !tonesOpen)}
    >
      ✋{tone}
    </button>
  </div>

  {#if tonesOpen}
    <div class="picker-bar tones" role="radiogroup" aria-label={t("spaceEditor.skinTone")}>
      {#each SKIN_TONES as modifier, index (index)}
        <button
          class="bar-button"
          role="radio"
          aria-checked={index === toneIndex}
          aria-label={t(`spaceEditor.${TONE_KEYS[index]}`)}
          title={t(`spaceEditor.${TONE_KEYS[index]}`)}
          {@attach (node) => {
            if (index === toneIndex) node.focus();
          }}
          onclick={() => chooseTone(index)}
        >
          <span class="tone-glyph">✋{modifier}</span>
        </button>
      {/each}
    </div>
  {:else}
    <div class="picker-bar" role="tablist" tabindex="-1" aria-label={t("spaceEditor.emojiCategories")} onkeydown={handleTabsKeydown}>
      {#each tabs as key, index (key)}
        <button
          class="bar-button"
          role="tab"
          aria-selected={key === currentKey}
          tabindex={key === (currentKey === "results" ? tabs[0] : currentKey) ? 0 : -1}
          aria-label={t(`spaceEditor.${key}`)}
          title={t(`spaceEditor.${key}`)}
          onclick={() => showSection(index)}
        >
          {@render categoryIcon(key)}
        </button>
      {/each}
    </div>
  {/if}

  <!-- One focus stop: arrows walk the emoji, the active one named through aria-activedescendant. -->
  <div
    class="picker-grid"
    bind:this={gridEl}
    role="listbox"
    tabindex="0"
    aria-label={t("spaceEditor.chooseEmoji")}
    aria-activedescendant={layout.items.length > 0 ? `emoji-option-${active}` : undefined}
    onscroll={(event) => (scrollTop = event.currentTarget.scrollTop)}
    onkeydown={handleGridKeydown}
    onclick={(event) => {
      const option = (event.target as HTMLElement).closest<HTMLElement>("[data-index]");
      if (option) pick(layout.items[Number(option.dataset.index)]);
    }}
    {@attach trackViewport}
  >
    {#if columns > 0 && layout.items.length === 0}
      <p class="picker-empty">{t("spaceEditor.noEmojiFound")}</p>
    {/if}
    <div class="picker-rows" style="height: {layout.rows.length * ROW_HEIGHT}px; --columns: {columns}">
      {#each visibleRows as { row, index } (index)}
        <div class="picker-row" class:header={"header" in row} style:transform="translateY({index * ROW_HEIGHT}px)">
          {#if "header" in row}
            {row.header}
          {:else}
            {#each layout.items.slice(row.start, row.end) as emoji, offset (offset)}
              {@const item = row.start + offset}
              {@const name = emojiName(catalog, emoji)}
              <div
                class="picker-cell"
                class:active={item === active}
                class:selected={emoji === selected}
                id="emoji-option-{item}"
                role="option"
                aria-selected={item === active}
                aria-label={name}
                title={name}
                data-index={item}
              >
                {emoji}
              </div>
            {/each}
          {/if}
        </div>
      {/each}
    </div>
  </div>
</div>

<style>
  .emoji-picker {
    display: flex;
    flex-direction: column;
    gap: var(--space-6);
    height: 100%;
    min-height: 0;
  }

  .picker-search {
    display: flex;
    align-items: center;
    gap: var(--space-6);
  }

  .tone-button {
    flex: none;
    display: grid;
    place-items: center;
    width: var(--control-height-lg);
    height: var(--control-height-lg);
    padding: 0;
    border: 0;
    border-radius: var(--radius-md);
    background: transparent;
    font-size: var(--font-size-xl);
    line-height: 1;
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .tone-button:hover,
  .tone-button.open {
    background: var(--bg-hover);
  }

  .picker-bar {
    display: flex;
    gap: 1px;
    padding-bottom: var(--space-6);
    border-bottom: 1px solid var(--separator);
  }

  .bar-button {
    flex: 1 1 0;
    min-width: 0;
    height: var(--control-height-sm);
    display: grid;
    place-items: center;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .bar-button:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .bar-button[aria-selected="true"],
  .bar-button[aria-checked="true"] {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .tone-button:focus-visible,
  .bar-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .tone-glyph {
    font-size: var(--font-size-xl);
    line-height: 1;
  }

  .picker-grid {
    position: relative;
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    overscroll-behavior: contain;
    outline: none;
    border-radius: var(--radius-sm);
  }

  .picker-grid:focus-visible .picker-cell.active {
    box-shadow: inset 0 0 0 2px var(--accent);
  }

  /* No transition: Reduce motion gives every element a near-zero one, which would hold the old height
     and offsets for a frame, so a scroll to a section just laid out would land short. */
  .picker-rows,
  .picker-row {
    transition: none;
  }

  .picker-rows {
    position: relative;
  }

  .picker-row {
    position: absolute;
    inset: 0 0 auto;
    height: 32px;
    display: grid;
    grid-template-columns: repeat(var(--columns), minmax(0, 1fr));
  }

  .picker-row.header {
    display: flex;
    align-items: flex-end;
    padding: 0 var(--space-4) var(--space-4);
    box-sizing: border-box;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  /* Apple Color Emoji first: the system font's own fallback would size some glyphs differently. */
  .picker-cell {
    display: grid;
    place-items: center;
    border-radius: var(--radius-sm);
    font-family: "Apple Color Emoji", system-ui, sans-serif;
    font-size: var(--font-size-3xl);
    line-height: 1;
    cursor: pointer;
    user-select: none;
  }

  .picker-cell:hover,
  .picker-cell.active {
    background: var(--bg-hover);
  }

  .picker-cell.selected {
    background: var(--accent-tint-18);
  }

  .picker-empty {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
    margin: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }
</style>
