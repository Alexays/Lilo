<script lang="ts">
  import { untrack } from "svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { createFrameScheduler } from "../../lib/motion/frameScheduler";
  import { t } from "../../lib/i18n/state.svelte";
  import { formatShortcut, parseInput, type CommandScope } from "../../lib/inputParser";
  import { cubicInOut } from "svelte/easing";
  import { fade, scale } from "svelte/transition";
  import {
    autocompleteSelected,
    closeCommandBar,
    dismissAutofill,
    consumeSelectAllOnOpen,
    executeRawQuery,
    executeRawQueryInNewTab,
    executeResult,
    executeSelected,
    executeSelectedInNewTab,
    getActiveScope,
    getAutocompleteSuggestion,
    getCommandBarOpenRequestId,
    getQuery,
    getResults,
    getSections,
    getSelectedIndex,
    getSelectedResult,
    getSelectedResultKeys,
    cancelMoveTab,
    isCommandBarOpen,
    isMovingTab,
    runSelectedResultKey,
    type ResultKey,
    selectNext,
    selectPrev,
    setCommandBarScope,
    setQuery,
    setSelectedIndex,
  } from "../../stores/commandBar.svelte";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { getTabs } from "../../stores/tabs.svelte";
  import type { CommandResult } from "../../stores/commandBarSearch.svelte";
  import {
    buildTabFaviconLookup,
    resolveResultIcon,
  } from "./commandBarIcons";

  const SCOPE_HINTS: Array<{
    prefix: string;
    labelKey: string;
    scope: CommandScope;
  }> = [
    { prefix: "", labelKey: "commandBar.scopeAll", scope: "all" },
    { prefix: ":", labelKey: "commandBar.scopeActions", scope: "action" },
    { prefix: ">", labelKey: "commandBar.scopeTerminal", scope: "terminal" },
    { prefix: "@", labelKey: "commandBar.scopeTabs", scope: "tab" },
    { prefix: "#", labelKey: "commandBar.scopeBookmarks", scope: "bookmark" },
    { prefix: "/", labelKey: "commandBar.scopeHistory", scope: "history" },
    { prefix: "<", labelKey: "commandBar.scopeArchive", scope: "archive" },
  ];
  const scopeHints = $derived(
    SCOPE_HINTS.filter((hint) => hint.scope !== "terminal" || getSetting("terminalEnabled", "true") !== "false").map(
      (hint) => ({ ...hint, label: t(hint.labelKey) }),
    ),
  );

  const RESULT_KEY_HINTS: Record<ResultKey, { keys: string; labelKey: string }> = {
    newTab: { keys: "Cmd+Enter", labelKey: "commandBar.hintNewTab" },
    split: { keys: "Opt+Enter", labelKey: "commandBar.hintSplit" },
    peek: { keys: "Shift+Enter", labelKey: "commandBar.hintPeek" },
    copy: { keys: "Cmd+C", labelKey: "commandBar.hintCopyLink" },
    close: { keys: "Cmd+Backspace", labelKey: "commandBar.hintCloseTab" },
    remove: { keys: "Cmd+Backspace", labelKey: "common.remove" },
    move: { keys: "Cmd+M", labelKey: "commandBar.hintMove" },
  };

  type Segment = { text: string; highlighted: boolean };

  function segments(text: string, highlights?: number[]): Segment[] {
    if (!highlights?.length) return [{ text, highlighted: false }];
    const set = new Set(highlights);
    const out: Segment[] = [];
    let buf = "";
    let wasHl = false;
    for (let i = 0; i < text.length; i++) {
      const hl = set.has(i);
      if (hl !== wasHl) {
        if (buf) out.push({ text: buf, highlighted: wasHl });
        buf = text[i]!;
        wasHl = hl;
      } else {
        buf += text[i];
      }
    }
    if (buf) out.push({ text: buf, highlighted: wasHl });
    return out;
  }

  const commandBarOpen = $derived(isCommandBarOpen());
  const activeScope = $derived(getActiveScope());
  const query = $derived(getQuery());
  // What was typed past the scope prefix: a bare prefix is an empty scope, not a search.
  const scopedQuery = $derived(parseInput(query, activeScope).query.trim());
  const results = $derived(getResults());
  const sections = $derived(getSections());
  const selectedIndex = $derived(getSelectedIndex());
  const selectedResult = $derived(getSelectedResult());
  const selectedKeys = $derived(getSelectedResultKeys());
  const movingTab = $derived(isMovingTab());
  const autocompleteSuggestion = $derived(getAutocompleteSuggestion());
  const autocompleteSuffix = $derived(
    autocompleteSuggestion &&
      autocompleteSuggestion
        .toLowerCase()
        .startsWith(query.trim().toLowerCase())
      ? autocompleteSuggestion.slice(query.trim().length)
      : "",
  );
  // The completion continues the text at its end: with the caret anywhere else it is neither shown nor taken.
  let caretAtEnd = $state(true);
  function trackCaret() {
    if (!inputEl) return;
    caretAtEnd = inputEl.selectionStart === inputEl.value.length && inputEl.selectionStart === inputEl.selectionEnd;
  }
  // Built once per open: tracking the tabs would rebuild it on every favicon or title update.
  const tabFavicons = $derived.by(() => {
    void commandBarOpen;
    return untrack(() => buildTabFaviconLookup(getTabs()));
  });

  let commandBarEl: HTMLDivElement | undefined = $state();
  let commandBarContentEl: HTMLDivElement | undefined = $state();
  let inputEl: HTMLInputElement | undefined = $state();
  const heightAnimationFrame = createFrameScheduler();
  let panelHadResults = false;
  let disposeHeightTransition: (() => void) | undefined;

  function finishHeightAnimation() {
    if (!commandBarEl) {
      return;
    }

    disposeHeightTransition?.();
    disposeHeightTransition = undefined;
    commandBarEl.style.height = "";
  }

  function measureCommandBarHeight(): number | undefined {
    if (!commandBarEl || !commandBarContentEl) {
      return undefined;
    }

    // With no inline height the panel already sits at its natural size, so the content's
    // rendered height is the target; only a mid-animation panel needs the auto toggle.
    if (!commandBarEl.style.height) {
      const height = commandBarContentEl.offsetHeight;
      return height > 0 ? height : undefined;
    }

    const previousHeight = commandBarEl.style.height;
    const previousTransition = commandBarEl.style.transition;
    commandBarEl.style.height = "auto";
    commandBarEl.style.transition = "none";
    const nextHeight = Math.ceil(
      commandBarContentEl.getBoundingClientRect().height,
    );
    commandBarEl.style.height = previousHeight;
    void commandBarEl.offsetHeight; // flush layout
    commandBarEl.style.transition = previousTransition;

    return nextHeight > 0 ? nextHeight : undefined;
  }

  function animateCommandBarHeight() {
    heightAnimationFrame.cancel();

    const panel = commandBarEl;
    const nextHeight = measureCommandBarHeight();
    if (!panel || !nextHeight) {
      return;
    }

    const startHeight = Math.ceil(panel.getBoundingClientRect().height);
    const hasResults = results.length > 0;
    const crossesEmpty = hasResults !== panelHadResults;
    panelHadResults = hasResults;
    const delta = Math.abs(startHeight - nextHeight);

    // A height transition relayouts the panel under the backdrop blur every frame: only the
    // empty/non-empty switch and large jumps animate, smaller changes snap to the natural height.
    if (delta < 1 || (!crossesEmpty && delta <= 40)) {
      finishHeightAnimation();
      return;
    }

    disposeHeightTransition?.();
    panel.style.height = `${startHeight}px`;
    void panel.offsetHeight; // flush layout
    panel.style.height = `${nextHeight}px`;

    const handleTransitionEnd = (event: TransitionEvent) => {
      if (event.propertyName !== "height") {
        return;
      }

      finishHeightAnimation();
    };

    panel.addEventListener("transitionend", handleTransitionEnd);
    disposeHeightTransition = () => {
      panel.removeEventListener("transitionend", handleTransitionEnd);
    };
  }

  function scheduleCommandBarHeightAnimation() {
    heightAnimationFrame.schedule(animateCommandBarHeight);
  }

  function focusCommandBarInput(selectAll: boolean, attempts = 0) {
    inputEl?.focus();
    if (!inputEl) return;

    if (selectAll) {
      inputEl.select();
    } else {
      const end = inputEl.value.length;
      inputEl.setSelectionRange(end, end);
    }
    trackCaret();

    if (document.activeElement !== inputEl && attempts < 3) {
      requestAnimationFrame(() => focusCommandBarInput(selectAll, attempts + 1));
    }
  }

  $effect(() => {
    void getCommandBarOpenRequestId();
    if (commandBarOpen && inputEl) {
      const selectAll = consumeSelectAllOnOpen();
      requestAnimationFrame(() => focusCommandBarInput(selectAll));
    }
  });

  $effect(() => {
    if (!commandBarOpen) {
      heightAnimationFrame.cancel();
      finishHeightAnimation();
      panelHadResults = false;
    }
  });

  $effect(() => {
    if (!commandBarOpen || !commandBarContentEl) {
      return;
    }

    void query.length;
    void sections.length;
    for (const section of sections) void section.items.length;

    scheduleCommandBarHeightAnimation();
  });

  $effect(() => {
    const idx = selectedIndex;
    if (!commandBarOpen) return;
    commandBarContentEl
      ?.querySelector<HTMLElement>(`#cb-result-${idx}`)
      ?.scrollIntoView({ block: "nearest" });
  });

  $effect(() => {
    if (!commandBarOpen) {
      return;
    }

    window.addEventListener("resize", scheduleCommandBarHeightAnimation);
    return () => window.removeEventListener("resize", scheduleCommandBarHeightAnimation);
  });

  // The backdrop leaves the sidebar uncovered, so clicks there never reach it: dismiss on any
  // pointerdown outside the panel (the sidebar click itself still goes through, no preventDefault).
  $effect(() => {
    if (!commandBarOpen) {
      return;
    }

    const handleWindowPointerDown = (event: PointerEvent) => {
      const target = event.target as Node | null;
      if (commandBarEl && target && !commandBarEl.contains(target)) {
        closeCommandBar();
      }
    };

    window.addEventListener("pointerdown", handleWindowPointerDown, true);

    return () => {
      window.removeEventListener("pointerdown", handleWindowPointerDown, true);
    };
  });

  // A row scrolled under a still pointer gets a replayed mouse event: only a pointer that moved picks
  // a row, so the arrow keys keep the selection.
  let lastPointer = "";
  function selectUnderPointer(event: MouseEvent, index: number) {
    const at = `${event.clientX},${event.clientY}`;
    if (at === lastPointer) return;
    lastPointer = at;
    setSelectedIndex(index);
  }

  // A click takes Return's modifiers: Command (or the middle button) opens a new tab, Option a split, Shift a peek.
  function runClickedRow(event: MouseEvent, index: number, result: CommandResult) {
    if (event.button !== 0 && event.button !== 1) return;
    event.preventDefault();
    setSelectedIndex(index);
    if ((event.altKey && runSelectedResultKey("split")) || (event.shiftKey && runSelectedResultKey("peek"))) return;
    if (event.metaKey || event.button === 1) executeSelectedInNewTab();
    else executeResult(result);
  }

  const SCOPE_PREFIX_CHARS = new Set(SCOPE_HINTS.map((hint) => hint.prefix).filter(Boolean));
  const escapeLeavesScope = $derived(query.length > 0 && SCOPE_PREFIX_CHARS.has(query[0]!));

  function handleKeydown(e: KeyboardEvent) {
    // The grey inline completion counts as typed while it shows.
    const completionShown = autocompleteSuffix !== "" && caretAtEnd;
    switch (e.key) {
      case "Escape":
        e.preventDefault();
        if (movingTab) {
          cancelMoveTab();
        } else if (escapeLeavesScope) {
          setCommandBarScope("all");
        } else {
          closeCommandBar();
        }
        break;
      case "ArrowDown":
        e.preventDefault();
        selectNext();
        break;
      case "ArrowUp":
        e.preventDefault();
        selectPrev();
        break;
      case "ArrowRight":
        // Accept the inline completion; otherwise the arrow moves the caret.
        if (completionShown) {
          e.preventDefault();
          setQuery(autocompleteSuggestion);
        }
        break;
      case "Enter": {
        e.preventDefault();
        if ((e.altKey && runSelectedResultKey("split")) || (e.shiftKey && runSelectedResultKey("peek"))) break;
        // The ghost text only ever names what the selected top row opens, so Enter runs the row.
        if (results.length === 0) {
          if (e.metaKey) executeRawQueryInNewTab();
          else executeRawQuery();
        } else if (e.metaKey) {
          executeSelectedInNewTab();
        } else {
          executeSelected();
        }
        break;
      }
      case "Tab":
        e.preventDefault();
        if (!caretAtEnd) break;
        if (autocompleteSuggestion) {
          setQuery(autocompleteSuggestion);
        } else {
          autocompleteSelected();
        }
        break;
      case "Backspace":
      case "Delete":
        if (e.key === "Delete" && !e.metaKey && completionShown) {
          e.preventDefault();
          dismissAutofill();
          break;
        }
        // Cmd+Delete closes the selected tab, or removes a history entry or a deletable omnibox suggestion.
        if (e.metaKey && (runSelectedResultKey("close") || runSelectedResultKey("remove"))) e.preventDefault();
        break;
      case "m":
        // Taken only on a tab row: elsewhere Cmd+M keeps minimizing the window.
        if (e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey && runSelectedResultKey("move")) e.preventDefault();
        break;
      case "c":
        // Selected input text copies as usual.
        if (
          e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey &&
          inputEl?.selectionStart === inputEl?.selectionEnd &&
          runSelectedResultKey("copy")
        ) {
          e.preventDefault();
        }
        break;
    }
  }

  function placeholder(): string {
    if (movingTab) return t("commandBar.placeholderMove");
    switch (activeScope) {
      case "action":
        return t("commandBar.placeholderAction");
      case "terminal":
        return t("commandBar.placeholderTerminal");
      case "tab":
        return t("commandBar.placeholderTab");
      case "bookmark":
        return t("commandBar.placeholderBookmark");
      case "history":
        return t("commandBar.placeholderHistory");
      case "archive":
        return t("commandBar.placeholderArchive");
      case "all":
        return t("commandBar.placeholderAll");
    }
  }

  function emptyStateTitle(): string {
    if (scopedQuery) {
      return t("commandBar.emptyTitleNoMatches");
    }

    switch (activeScope) {
      case "action":
        return t("commandBar.emptyTitleAction");
      case "terminal":
        return t("commandBar.emptyTitleTerminal");
      case "tab":
        return t("commandBar.emptyTitleTab");
      case "bookmark":
        return t("commandBar.emptyTitleBookmark");
      case "history":
        return t("commandBar.emptyTitleHistory");
      case "archive":
        return t("commandBar.emptyTitleArchive");
      case "all":
        return t("commandBar.emptyTitleAll");
    }
  }

  function emptyStateSubtitle(): string {
    if (scopedQuery) {
      return t("commandBar.emptySubtitleNoMatches");
    }

    switch (activeScope) {
      case "action":
        return t("commandBar.emptySubtitleAction");
      case "terminal":
        return t("commandBar.emptySubtitleTerminal");
      case "tab":
        return t("commandBar.emptySubtitleTab");
      case "bookmark":
        return t("commandBar.emptySubtitleBookmark");
      case "history":
        return t("commandBar.emptySubtitleHistory");
      case "archive":
        return t("commandBar.emptySubtitleArchive");
      case "all":
        return t("commandBar.emptySubtitleAll");
    }
  }
</script>

<!-- Single line: whitespace inside would render between the highlight segments. -->
{#snippet highlightedText(text: string, highlights?: number[])}{#each segments(text, highlights) as seg, segIndex (`${seg.text}-${seg.highlighted ? '1' : '0'}-${segIndex}`)}{#if seg.highlighted}<mark class="result-hl">{seg.text}</mark>{:else}{seg.text}{/if}{/each}{/snippet}

{#if commandBarOpen}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="command-bar-backdrop chrome-content-overlay-root"
    class:sidebar-hidden={!isSidebarVisible()}
    use:reportInteractiveZone={{
      id: "command-bar-backdrop",
      active: commandBarOpen,
    }}
    out:fade={{ duration: prefersReducedMotion() ? 0 : 145, easing: cubicInOut }}
    onkeydown={handleKeydown}
  >
    <div
      bind:this={commandBarEl}
      class="command-bar chrome-floating-surface"
      out:scale={{ duration: prefersReducedMotion() ? 0 : 165, start: 1, opacity: 1, easing: cubicInOut }}
    >
      <div bind:this={commandBarContentEl} class="command-bar-content">
        <div class="command-bar-input-row">
          <span class="command-bar-icon" aria-hidden="true">
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
              <circle cx="5" cy="5" r="3.4" stroke="currentColor" stroke-width="1.4" />
              <path d="M7.6 7.6 10.4 10.4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
            </svg>
          </span>
          <div class="command-bar-input-wrap">
            {#if autocompleteSuffix && caretAtEnd}
              <div class="command-bar-autocomplete" aria-hidden="true">
                <span class="command-bar-autocomplete-query">{query.trim()}</span
                ><span>{autocompleteSuffix}</span>
              </div>
            {/if}
            <input
              bind:this={inputEl}
              class="command-bar-input"
              type="text"
              placeholder={placeholder()}
              spellcheck="false"
              autocomplete="off"
              role="combobox"
              aria-label={t("commandBar.inputLabel")}
              aria-expanded={sections.length > 0}
              aria-autocomplete="list"
              aria-controls="cb-results"
              aria-activedescendant={results.length > 0 ? `cb-result-${selectedIndex}` : undefined}
              value={query}
              oninput={(e) => {
                setQuery((e.target as HTMLInputElement).value, !(e instanceof InputEvent && e.inputType.startsWith("delete")));
                trackCaret();
              }}
              onkeyup={trackCaret}
              onpointerup={trackCaret}
              onselect={trackCaret}
            />
          </div>
        </div>

        <div class="command-bar-toolbar">
          <div class="command-bar-scopes">
            {#each scopeHints as hint (hint.scope)}
              <button
                type="button"
                class:selected={!movingTab && hint.scope === activeScope}
                class="scope-hint"
                disabled={movingTab}
                onmousedown={(e) => e.preventDefault()}
                onclick={() => setCommandBarScope(hint.scope)}
              >
                {#if hint.prefix}
                  <span class="scope-hint-prefix">{hint.prefix}</span>
                {/if}
                <span class="scope-hint-label">{hint.label}</span>
              </button>
            {/each}
          </div>

        </div>

        {#if sections.length > 0}
          <div class="command-bar-results" id="cb-results" role="listbox" aria-label={t("commandBar.resultsLabel")}>
            {#each sections as section (section.id)}
              <div class="command-bar-section" role="group" aria-label={section.title}>
                <div class="command-bar-section-header" aria-hidden="true">
                  <span class="command-bar-section-title">{section.title}</span>
                </div>

                <div class="command-bar-section-results">
                  {#each section.items as entry (entry.result.id)}
                    {@const iconSpec = resolveResultIcon(entry.result, tabFavicons)}
                    <div
                      id={`cb-result-${entry.index}`}
                      class="command-bar-result"
                      class:selected={entry.index === selectedIndex}
                      role="option"
                      tabindex="-1"
                      aria-selected={entry.index === selectedIndex}
                      onmousedown={(e) => runClickedRow(e, entry.index, entry.result)}
                      onmousemove={(e) => selectUnderPointer(e, entry.index)}
                    >
                      {#if iconSpec.type === "favicon"}
                        <span class="result-icon result-icon-favicon">
                          <span class="result-favicon-fallback" aria-hidden="true">{iconSpec.fallback}</span>
                          <img
                            class="result-favicon-image"
                            src={iconSpec.src}
                            alt=""
                            draggable="false"
                            onerror={(event) => {
                              (event.currentTarget as HTMLImageElement).hidden = true;
                            }}
                          />
                        </span>
                      {:else if iconSpec.type === "line"}
                        <span class={`result-icon result-icon-line result-icon-${entry.result.kind}`}>
                          <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">
                            <path d={iconSpec.path} stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
                          </svg>
                        </span>
                      {:else if iconSpec.type === "glyph"}
                        <span class={`result-icon result-icon-${entry.result.kind}`}>{iconSpec.glyph}</span>
                      {:else}
                        <span class="result-icon result-icon-letter">{iconSpec.letter}</span>
                      {/if}

                      <div class="result-main">
                        <div class="result-topline">
                          <span class="result-title">{@render highlightedText(entry.result.title, entry.result.titleHighlights)}</span>
                        </div>

                        {#if entry.result.subtitle}
                          <div class="result-subtitle">{@render highlightedText(entry.result.subtitle, entry.result.subtitleHighlights)}</div>
                        {/if}
                      </div>

                      {#if entry.result.helper}
                        <span class="result-helper">{entry.result.helper}</span>
                      {/if}
                    </div>
                  {/each}
                </div>
              </div>
            {/each}
          </div>
        {:else}
          <div class="command-bar-empty">
            <p class="command-bar-empty-title">{emptyStateTitle()}</p>
            <p class="command-bar-empty-subtitle">{emptyStateSubtitle()}</p>
          </div>
        {/if}

        <div class="command-bar-footer" aria-hidden="true">
          <span class="footer-hints">
            <span class="footer-hint"><kbd>{formatShortcut("Enter")}</kbd><span>{selectedResult?.hint || t("common.open")}</span></span>
            {#each selectedKeys as key (key)}
              <span class="footer-hint">
                <kbd>{formatShortcut(RESULT_KEY_HINTS[key].keys)}</kbd><span>{t(key === "newTab" && activeScope === "terminal" ? "commandBar.hintSplit" : RESULT_KEY_HINTS[key].labelKey)}</span>
              </span>
            {/each}
            {#if autocompleteSuggestion && caretAtEnd}
              <span class="footer-hint"><kbd>Tab</kbd><span>{t("commandBar.hintComplete")}</span></span>
            {/if}
          </span>
          <span class="footer-hint"><kbd>Esc</kbd><span>{t(movingTab || escapeLeavesScope ? "common.back" : "common.close")}</span></span>
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  .command-bar-backdrop {
    --command-bar-shell-padding: 16px;
    --command-bar-anchor-top: clamp(18px, 5vh, 52px);
    position: fixed;
    isolation: isolate;
    overflow: hidden;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: var(--command-bar-shell-padding);
    padding-top: calc(
      var(--command-bar-shell-padding) + var(--command-bar-anchor-top)
    );
    z-index: 60;
    pointer-events: auto;
    background: var(--chrome-overlay-backdrop-tint);
    backdrop-filter: blur(var(--chrome-overlay-backdrop-blur)) saturate(1.04);
    animation: command-bar-backdrop-fade var(--motion-duration-slow)
      var(--motion-ease-organic);
  }

  .command-bar-backdrop::before {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: inherit;
    background: radial-gradient(
        circle at 50% 38%,
        color-mix(in srgb, white 18%, transparent),
        transparent 42%
      ),
      linear-gradient(180deg, color-mix(in srgb, white 6%, transparent), transparent 32%);
    opacity: 0.9;
    pointer-events: none;
    animation: command-bar-atmosphere var(--motion-duration-slow)
      var(--motion-ease-organic);
  }

  .command-bar {
    --cb-result-hover: color-mix(
      in srgb,
      var(--bg-hover) 78%,
      color-mix(in srgb, white 18%, transparent)
    );
    width: min(620px, calc(100% - 28px));
    max-height: min(
      520px,
      calc(
        100% - var(--command-bar-anchor-top) -
          (var(--command-bar-shell-padding) * 2)
      )
    );
    color: var(--text-primary);
    overflow: hidden;
    display: flex;
    flex-direction: column;
    transform-origin: 50% 0;
    background: var(--chrome-overlay-surface-strong);
    animation: command-bar-rise 380ms var(--motion-ease-bounce);
    transition: height var(--motion-duration-normal) var(--motion-ease-organic);
    will-change: transform, opacity;
    contain: layout style;
  }

  .command-bar-content {
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    min-height: 0;
  }

  .command-bar-input-row {
    align-items: center;
    border: 1px solid var(--chrome-overlay-border);
    border-radius: var(--radius-md);
    box-shadow: inset 0 1px 0 color-mix(in srgb, white 14%, transparent);
    display: flex;
    gap: 8px;
    /* Edges line up down the panel: input, chips and rows at the results' 10px inset; the search
       icon, section titles, row tiles and footer keys 9px further in. */
    margin: 14px 10px 0;
    padding: 8px;
    background: color-mix(in srgb, var(--bg-primary) 74%, transparent);
    flex: 0 0 auto;
    animation: command-bar-content-fade var(--motion-duration-normal) 40ms both;
  }

  .command-bar-icon {
    align-items: center;
    background: color-mix(in srgb, var(--bg-hover) 74%, transparent);
    border-radius: var(--radius-sm);
    color: color-mix(in srgb, var(--text-primary) 66%, transparent);
    display: inline-flex;
    flex-shrink: 0;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-bold);
    height: 22px;
    justify-content: center;
    width: 22px;
  }

  .command-bar-input {
    background: transparent;
    border: none;
    color: var(--text-primary);
    font-family:
      "SF Pro Display",
      "SF Pro Text",
      -apple-system,
      BlinkMacSystemFont,
      sans-serif;
    font-size: var(--font-size-lg);
    letter-spacing: 0;
    line-height: 20px;
    outline: none;
    position: relative;
    width: 100%;
    z-index: 1;
  }

  .command-bar-input::placeholder {
    color: color-mix(in srgb, var(--text-muted) 88%, transparent);
  }

  .command-bar-input-wrap {
    flex: 1;
    min-width: 0;
    position: relative;
  }

  .command-bar-autocomplete {
    color: color-mix(in srgb, var(--text-muted) 52%, transparent);
    font-family:
      "SF Pro Display",
      "SF Pro Text",
      -apple-system,
      BlinkMacSystemFont,
      sans-serif;
    font-size: var(--font-size-lg);
    inset: 0;
    letter-spacing: 0;
    line-height: 20px;
    overflow: hidden;
    pointer-events: none;
    position: absolute;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .command-bar-autocomplete-query {
    color: transparent;
  }

  .command-bar-toolbar {
    align-items: center;
    display: flex;
    flex-wrap: nowrap;
    gap: 6px;
    justify-content: flex-start;
    overflow: hidden;
    padding: 8px 10px 4px;
    flex: 0 0 auto;
    animation: command-bar-content-fade var(--motion-duration-normal) 55ms both;
  }

  .command-bar-scopes {
    display: flex;
    flex: 1 1 auto;
    /* A narrow bar wraps the chips: clipped, the last scopes could not be clicked. */
    flex-wrap: wrap;
    gap: 4px;
    min-width: 0;
  }

  .scope-hint {
    align-items: center;
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--radius-chip);
    color: var(--text-secondary);
    cursor: pointer;
    display: inline-flex;
    gap: 4px;
    flex: 0 0 auto;
    padding: 2px 6px;
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.01em;
    line-height: 1;
    transition:
      background var(--transition-fast),
      border-color var(--transition-fast),
      color var(--transition-fast);
    -webkit-appearance: none;
    appearance: none;
  }

  .scope-hint:hover:not(:disabled) {
    background: color-mix(in srgb, var(--bg-hover) 64%, transparent);
    color: var(--text-primary);
  }

  /* The Space picker of a tab move has no scope. */
  .scope-hint:disabled {
    cursor: default;
    opacity: var(--disabled-opacity);
  }

  .scope-hint.selected {
    background: color-mix(in srgb, var(--bg-hover) 88%, transparent);
    border-color: color-mix(
      in srgb,
      var(--accent) 10%,
      var(--chrome-overlay-border)
    );
    color: var(--text-primary);
  }

  .scope-hint:focus-visible {
    border-color: color-mix(
      in srgb,
      var(--accent) 22%,
      var(--chrome-overlay-border)
    );
    outline: none;
  }

  /* One slot width for every prefix glyph, in the label's font so both share a line box. */
  .scope-hint-prefix {
    color: currentColor;
    font-weight: var(--font-weight-bold);
    text-align: center;
    width: 1em;
  }

  .command-bar-results {
    display: grid;
    gap: 8px;
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    overscroll-behavior: contain;
    padding: 4px 10px 10px;
    animation: command-bar-content-fade var(--motion-duration-overlay) 70ms both;
  }

  .command-bar-section {
    display: grid;
    gap: 4px;
  }

  /* On the search icon's edge: the input row's padding plus its 1px border. */
  .command-bar-section-header {
    padding: 0 calc(var(--space-8) + 1px);
  }

  .command-bar-section-title {
    color: var(--text-primary);
    font-size: var(--font-size-3xs);
    font-weight: var(--font-weight-bold);
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }

  .command-bar-section-results {
    display: grid;
    gap: 4px;
  }

  .command-bar-result {
    align-items: center;
    border: 1px solid transparent;
    border-radius: var(--radius-md);
    cursor: pointer;
    display: grid;
    gap: 8px;
    /* The helper chip shows whole while it fits; past that it truncates, the title keeping a readable minimum. */
    grid-template-columns: auto minmax(min(180px, 50%), 1fr) minmax(0, max-content);
    min-height: 38px;
    padding: 6px 8px;
    transition:
      background var(--transition-fast),
      border-color var(--transition-fast);
  }

  .command-bar-result:hover,
  .command-bar-result.selected {
    background: var(--cb-result-hover);
    border-color: color-mix(
      in srgb,
      var(--accent) 12%,
      var(--chrome-overlay-border)
    );
  }

  .result-icon {
    align-items: center;
    border-radius: var(--radius-sm);
    display: inline-flex;
    flex-shrink: 0;
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-bold);
    height: 22px;
    justify-content: center;
    letter-spacing: -0.03em;
    width: 22px;
  }

  .result-icon-action {
    background: var(--accent-tint-14);
    color: var(--text-primary);
  }

  /* A block svg centers on the tile's box, not on a text line's baseline. */
  .result-icon-line svg {
    display: block;
  }

  .result-icon-favicon {
    position: relative;
    background: color-mix(
      in srgb,
      var(--bg-hover) 74%,
      color-mix(in srgb, white 30%, transparent)
    );
    color: var(--text-primary);
    overflow: hidden;
  }

  .result-favicon-fallback {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
  }

  /* A favicon with transparent parts would show the initial through it: the initial waits for a failed load. */
  .result-icon-favicon:has(> img:not([hidden])) .result-favicon-fallback {
    visibility: hidden;
  }

  .result-favicon-image {
    position: absolute;
    inset: 3px;
    width: 16px;
    height: 16px;
    object-fit: contain;
    border-radius: var(--radius-xs);
  }

  .result-icon-letter {
    background: color-mix(
      in srgb,
      var(--bg-hover) 74%,
      color-mix(in srgb, white 30%, transparent)
    );
    color: var(--text-secondary);
  }

  .result-main {
    display: grid;
    gap: 1px;
    min-width: 0;
  }

  .result-topline {
    display: flex;
    min-width: 0;
  }

  .result-title {
    color: var(--text-primary);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .result-subtitle {
    color: var(--text-secondary);
    font-size: var(--font-size-2xs);
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .result-hl {
    background: transparent;
    color: color-mix(in srgb, var(--accent) 55%, var(--text-primary));
    font-weight: var(--font-weight-bold);
  }

  .result-helper {
    background: color-mix(in srgb, var(--bg-hover) 82%, transparent);
    border: 1px solid
      color-mix(in srgb, var(--chrome-overlay-border) 82%, transparent);
    border-radius: var(--radius-chip);
    color: var(--text-secondary);
    min-width: 0;
    overflow: hidden;
    padding: 0 8px;
    text-overflow: ellipsis;
  }

  /* Row chips and footer keys: one pill, in the system font, its text centered by the line box. */
  .result-helper,
  kbd {
    box-sizing: border-box;
    font-family: inherit;
    font-size: var(--font-size-2xs);
    font-variant-numeric: tabular-nums;
    font-weight: var(--font-weight-semibold);
    height: 16px;
    line-height: 14px;
    text-align: center;
    white-space: nowrap;
  }

  .command-bar-empty {
    display: grid;
    gap: 6px;
    padding: 20px 16px 18px;
    text-align: center;
  }

  .command-bar-empty-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    margin: 0;
  }

  .command-bar-empty-subtitle {
    color: var(--text-muted);
    font-size: var(--font-size-2xs);
    line-height: 1.45;
    margin: 0 auto;
    max-width: 34ch;
  }

  .command-bar-footer {
    align-items: center;
    border-top: 1px solid color-mix(in srgb, var(--chrome-overlay-border) 70%, transparent);
    display: flex;
    flex: 0 0 auto;
    gap: 12px;
    padding: 8px 20px 8px;
    animation: command-bar-content-fade var(--motion-duration-normal) 55ms both;
  }

  .footer-hint {
    align-items: center;
    color: var(--text-secondary);
    display: inline-flex;
    font-size: var(--font-size-2xs);
    line-height: 16px;
    font-weight: var(--font-weight-semibold);
    gap: 4px;
    opacity: 0.85;
    white-space: nowrap;
  }

  /* A hint that does not fit wraps onto a second line the fixed height hides: it drops whole,
     never as a cut word, and Esc keeps its place. */
  .footer-hints {
    display: flex;
    flex: 1;
    flex-wrap: wrap;
    gap: 0 10px;
    height: 16px;
    min-width: 0;
    overflow: hidden;
  }

  .result-icon-space,
  .result-icon-moveToSpace {
    font-family: inherit;
    font-size: var(--font-size-lg);
  }

  kbd {
    background: color-mix(in srgb, var(--bg-primary) 76%, transparent);
    border: 1px solid var(--chrome-overlay-border);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    min-width: 18px;
    padding: 0 4px;
  }

  @keyframes command-bar-rise {
    from {
      opacity: 0;
      transform: translateY(28px) scale(0.955);
    }
  }

  @keyframes command-bar-backdrop-fade {
    from {
      opacity: 0;
    }

    to {
      opacity: 1;
    }
  }

  @keyframes command-bar-atmosphere {
    from {
      opacity: 0;
      transform: scale(1.04);
    }

    to {
      opacity: 0.9;
      transform: scale(1);
    }
  }

  @keyframes command-bar-content-fade {
    from {
      opacity: 0;
      transform: translateY(4px);
    }

    to {
      opacity: 1;
      transform: translateY(0);
    }
  }

  @media (max-width: 640px) {
    .command-bar-backdrop {
      --command-bar-shell-padding: 8px;
      --command-bar-anchor-top: clamp(8px, 2.5vh, 18px);
    }

    .command-bar {
      width: calc(100% - 10px);
      max-height: calc(
        100% - var(--command-bar-anchor-top) -
          (var(--command-bar-shell-padding) * 2)
      );
    }

    .command-bar-input-row {
      margin-left: 6px;
      margin-right: 6px;
    }

    .command-bar-toolbar {
      padding-left: 6px;
      padding-right: 6px;
    }

    .command-bar-footer {
      display: none;
    }

    .result-helper {
      display: none;
    }

    .command-bar-toolbar {
      align-items: flex-start;
    }

    .command-bar-results {
      padding-left: 6px;
      padding-right: 6px;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .command-bar-backdrop,
    .command-bar-backdrop::before,
    .command-bar,
    .command-bar-input-row,
    .command-bar-toolbar,
    .command-bar-results,
    .command-bar-footer {
      animation: none;
      transition: none;
    }
  }
</style>
