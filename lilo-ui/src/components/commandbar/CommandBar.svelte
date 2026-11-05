<script lang="ts">
  import { untrack } from "svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { createFrameScheduler } from "../../lib/motion/frameScheduler";
  import { t } from "../../lib/i18n/state.svelte";
  import { formatShortcut, parseInput, scopePrefix, setTopLevelDomains, type CommandScope } from "../../lib/inputParser";
  import { TOP_LEVEL_DOMAINS } from "../../lib/topLevelDomains.gen";
  import { fade } from "svelte/transition";
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
    isCommandBarDocked,
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
  import { getAgentMood, isAgentsSpace } from "../../stores/agents.svelte";
  import { postMessage } from "../../lib/bridge";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import { isDesignSystemShellOpen, isHistoryShellOpen, isSettingsShellOpen } from "../../stores/panels.svelte";
  import { getOnboarding } from "../../stores/onboarding.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { getTabs } from "../../stores/tabs.svelte";
  import type { CommandResult } from "../../stores/commandBarSearch.svelte";
  import { buildTabFaviconLookup, LINE_ICONS, resolveResultIcon } from "./commandBarIcons";

  setTopLevelDomains(TOP_LEVEL_DOMAINS);

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
  const docked = $derived(isCommandBarDocked());
  // In place on a blank tab, the bar steps aside for a screen that covers the page.
  const shown = $derived(
    commandBarOpen &&
      !(docked && (isSettingsShellOpen() || isHistoryShellOpen() || isDesignSystemShellOpen() || getOnboarding().visible)),
  );
  const activeScope = $derived(getActiveScope());
  const query = $derived(getQuery());
  // A typed scope prefix shows as a token before the field; the query keeps it.
  const tokenPrefix = $derived(
    activeScope !== "all" && !isMovingTab() && query.trimStart().startsWith(scopePrefix(activeScope)) ? scopePrefix(activeScope) : "",
  );
  const fieldText = $derived(tokenPrefix ? query.trimStart().slice(tokenPrefix.length).trimStart() : query);
  const tokenLabel = $derived(tokenPrefix ? SCOPE_HINTS.find((hint) => hint.scope === activeScope)?.labelKey : undefined);
  // What was typed past the scope prefix: a bare prefix is an empty scope, not a search.
  const scopedQuery = $derived(parseInput(query, activeScope).query.trim());
  const results = $derived(getResults());
  const sections = $derived(getSections());
  const selectedIndex = $derived(getSelectedIndex());
  const selectedResult = $derived(getSelectedResult());
  const selectedKeys = $derived(getSelectedResultKeys());
  const movingTab = $derived(isMovingTab());
  const tileSection = $derived(sections.find((section) => section.tiles));
  const firstTile = $derived(tileSection?.items[0]?.index ?? -1);
  const lastTile = $derived(tileSection?.items.at(-1)?.index ?? -1);
  const inTiles = (index: number) => firstTile >= 0 && index >= firstTile && index <= lastTile;
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
    void shown;
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
    if (shown && inputEl) {
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
    if (!commandBarOpen || docked) {
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
        } else if (!docked) {
          closeCommandBar();
          postMessage("focusPage");
        }
        break;
      // The strip of chips counts as one row for the up and down arrows; the side arrows walk it.
      case "ArrowDown":
        e.preventDefault();
        if (inTiles(selectedIndex)) setSelectedIndex(lastTile);
        selectNext();
        break;
      case "ArrowUp":
        e.preventDefault();
        if (inTiles(selectedIndex)) setSelectedIndex(firstTile);
        selectPrev();
        if (inTiles(getSelectedIndex())) setSelectedIndex(firstTile);
        break;
      case "ArrowLeft":
        if (inTiles(selectedIndex)) {
          e.preventDefault();
          setSelectedIndex(Math.max(firstTile, selectedIndex - 1));
        }
        break;
      case "ArrowRight":
        if (inTiles(selectedIndex)) {
          e.preventDefault();
          setSelectedIndex(Math.min(lastTile, selectedIndex + 1));
        } else if (completionShown) {
          // Accept the inline completion; otherwise the arrow moves the caret.
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
        // Backspace before the field's text takes the scope token away and keeps the text.
        if (e.key === "Backspace" && tokenPrefix && !e.metaKey && inputEl?.selectionStart === 0 && inputEl.selectionEnd === 0) {
          e.preventDefault();
          setCommandBarScope("all");
          break;
        }
        if (!e.metaKey && completionShown) {
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

  // An address reads without its scheme, its highlights shifted along.
  function detail(result: CommandResult): { text: string; highlights?: number[] } {
    const text = result.subtitle ?? "";
    const scheme = result.url && text === result.url ? (/^https?:\/\//i.exec(text)?.[0].length ?? 0) : 0;
    if (!scheme) return { text, highlights: result.subtitleHighlights };
    return { text: text.slice(scheme), highlights: result.subtitleHighlights?.map((i) => i - scheme).filter((i) => i >= 0) };
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

{#snippet resultIcon(result: CommandResult)}
  {@const iconSpec = resolveResultIcon(result, tabFavicons)}
  {#if result.kind === "space" && isAgentsSpace(String(result.payload.spaceId))}
    <span class="result-icon">
      {#await import("../sidebar/AgentMascot.svelte") then { default: AgentMascot }}
        <AgentMascot mood={getAgentMood(String(result.payload.spaceId))} />
      {/await}
    </span>
  {:else if result.kind === "tab" && result.payload.agentId !== undefined}
    <span class="result-icon">
      {#await import("../agents/AgentTile.svelte") then { default: AgentTile }}
        <AgentTile agentId={String(result.payload.agentId)} />
      {/await}
      {#if result.payload.waiting}<span class="result-icon-dot" aria-hidden="true"></span>{/if}
    </span>
  {:else if iconSpec.type === "favicon"}
    <span class="result-icon result-icon-site" style:--site-hue={iconSpec.hue}>
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
    <span class="result-icon" class:result-icon-terminal={result.kind === "terminalTab" || result.kind === "closedTerminal"}>
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
        <path d={result.kind === "terminalTab" || result.kind === "closedTerminal" ? LINE_ICONS.prompt : iconSpec.path} stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
      {#if result.payload.waiting}<span class="result-icon-dot" aria-hidden="true"></span>{/if}
    </span>
  {:else if iconSpec.type === "glyph"}
    <span class="result-icon result-icon-glyph">{iconSpec.glyph}</span>
  {:else}
    <span class="result-icon result-icon-site result-icon-letter" style:--site-hue={iconSpec.hue}>{iconSpec.letter}</span>
  {/if}
{/snippet}

{#if shown}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="command-bar-backdrop chrome-content-overlay-root"
    class:sidebar-hidden={!isSidebarVisible()}
    class:docked
    use:reportInteractiveZone={{
      id: "command-bar-backdrop",
      active: shown,
    }}
    out:fade={{ duration: prefersReducedMotion() ? 0 : 120 }}
    onkeydown={handleKeydown}
  >
    <div
      bind:this={commandBarEl}
      class="command-bar float-surface"
    >
      <div bind:this={commandBarContentEl} class="command-bar-content">
        <div class="command-bar-header">
          <div class="command-bar-input-row">
            <svg class="command-bar-icon" width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <circle cx="7" cy="7" r="4.75" stroke="currentColor" stroke-width="1.5" />
              <path d="M10.5 10.5 14 14" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
            </svg>
            {#if tokenLabel}
              <span class="scope-token">{t(tokenLabel)}</span>
            {/if}
            <div class="command-bar-input-wrap">
              {#if autocompleteSuffix && caretAtEnd}
                <div class="command-bar-autocomplete" aria-hidden="true">
                  <span class="command-bar-autocomplete-query">{fieldText}</span
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
                aria-label={tokenLabel ? `${t("commandBar.inputLabel")}, ${t(tokenLabel)}` : t("commandBar.inputLabel")}
                aria-expanded={sections.length > 0}
                aria-autocomplete="list"
                aria-controls="cb-results"
                aria-activedescendant={results.length > 0 ? `cb-result-${selectedIndex}` : undefined}
                value={fieldText}
                oninput={(e) => {
                  const field = e.target as HTMLInputElement;
                  // A prefix typed first takes over from the token, as a press on its chip would.
                  const ownPrefix = SCOPE_HINTS.some((hint) => hint.prefix && field.value.startsWith(hint.prefix));
                  const typed = tokenPrefix && !ownPrefix ? (field.value ? `${tokenPrefix} ${field.value}` : tokenPrefix) : field.value;
                  setQuery(typed, !(e instanceof InputEvent && e.inputType.startsWith("delete")));
                  // A prefix just typed becomes the token: the field drops it, which the value binding would not see.
                  if (field.value !== fieldText) field.value = fieldText;
                  trackCaret();
                }}
                onkeyup={trackCaret}
                onpointerup={trackCaret}
                onselect={trackCaret}
              />
            </div>
            {#if autocompleteSuggestion && caretAtEnd}
              <span class="key-hint"><span>{t("commandBar.hintComplete")}</span><kbd>tab</kbd></span>
            {/if}
          </div>

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
                <span class="scope-hint-label">{hint.label}</span>
                {#if hint.prefix}
                  <span class="scope-hint-prefix" aria-hidden="true">{hint.prefix}</span>
                {/if}
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
                  {#if section.subtitle}<span class="command-bar-section-subtitle">{section.subtitle}</span>{/if}
                </div>

                <div class={section.tiles ? "command-bar-strip" : "command-bar-section-results"}>
                  {#each section.items as entry (entry.result.id)}
                    <div
                      id={`cb-result-${entry.index}`}
                      class={section.tiles ? "command-bar-chip" : "command-bar-result"}
                      class:selected={entry.index === selectedIndex}
                      role="option"
                      tabindex="-1"
                      aria-selected={entry.index === selectedIndex}
                      onmousedown={(e) => runClickedRow(e, entry.index, entry.result)}
                      onmousemove={(e) => selectUnderPointer(e, entry.index)}
                    >
                      {@render resultIcon(entry.result)}
                      {#if section.tiles}
                        <span class="chip-title">{entry.result.title}</span>
                      {:else}
                        {@const subtitle = detail(entry.result)}
                        <div class="result-main">
                          <span class="result-title">{@render highlightedText(entry.result.title, entry.result.titleHighlights)}</span>
                          {#if subtitle.text}
                            <span class="result-subtitle">{@render highlightedText(subtitle.text, subtitle.highlights)}</span>
                          {/if}
                        </div>

                        {#if entry.result.helper}
                          {#if entry.result.kind === "action"}
                            <kbd class="result-shortcut">{entry.result.helper}</kbd>
                          {:else}
                            <span class="result-helper">{entry.result.helper}</span>
                          {/if}
                        {/if}
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
            <span class="key-hint key-hint-default"><span>{selectedResult?.hint || t("common.open")}</span><kbd>{formatShortcut("Enter")}</kbd></span>
            {#each selectedKeys as key (key)}
              <span class="key-hint">
                <span>{t(key === "newTab" && activeScope === "terminal" ? "commandBar.hintSplit" : RESULT_KEY_HINTS[key].labelKey)}</span><kbd>{formatShortcut(RESULT_KEY_HINTS[key].keys)}</kbd>
              </span>
            {/each}
          </span>
          {#if !docked || movingTab || escapeLeavesScope}
            <span class="key-hint"><span>{t(movingTab || escapeLeavesScope ? "common.back" : "common.close")}</span><kbd>esc</kbd></span>
          {/if}
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  /* Clear: the page stays in view under the bar; the backdrop only catches the page area's clicks. */
  .command-bar-backdrop {
    position: fixed;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: 64px 16px 16px;
    z-index: 60;
    pointer-events: auto;
  }

  .command-bar-backdrop.docked {
    padding-top: clamp(40px, 13vh, 104px);
  }

  .command-bar {
    width: min(600px, 100%);
    max-height: 100%;
    border-radius: var(--radius-lg);
    overflow: hidden;
    display: flex;
    flex-direction: column;
    transform-origin: 50% 0;
    animation: command-bar-in var(--motion-duration-overlay) var(--motion-ease-spring);
    transition: height var(--motion-duration-normal) var(--motion-ease-organic);
    contain: layout style;
  }

  /* Part of the page rather than over it: a quiet edge, no shadow to lift it. */
  .docked .command-bar {
    max-height: calc(100% - 40px);
    box-shadow: 0 0 0 1px var(--float-border);
    animation: none;
  }

  .command-bar-content {
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    min-height: 0;
  }

  .command-bar-header {
    flex: none;
    border-bottom: 1px solid var(--separator);
  }

  .command-bar-input-row {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 52px;
    padding: 0 16px;
  }

  .command-bar-icon {
    flex: none;
    color: var(--text-secondary);
  }

  .command-bar-input,
  .command-bar-autocomplete {
    font: inherit;
    font-size: var(--font-size-modal);
    letter-spacing: 0;
    line-height: 24px;
  }

  .command-bar-input {
    position: relative;
    z-index: 1;
    width: 100%;
    padding: 0;
    border: none;
    background: transparent;
    color: var(--text-primary);
    outline: none;
  }

  .command-bar-input::placeholder {
    color: var(--text-muted);
  }

  .command-bar-input-wrap {
    position: relative;
    flex: 1;
    min-width: 0;
  }

  .command-bar-autocomplete {
    position: absolute;
    inset: 0;
    overflow: hidden;
    color: var(--text-muted);
    pointer-events: none;
    text-overflow: ellipsis;
    white-space: pre;
  }

  .command-bar-autocomplete-query {
    color: transparent;
  }

  .command-bar-scopes {
    display: flex;
    /* A narrow bar wraps the chips: clipped, the last scopes could not be clicked. */
    flex-wrap: wrap;
    gap: 2px;
    padding: 0 12px 10px;
  }

  .scope-hint,
  .scope-token {
    display: inline-flex;
    flex: none;
    align-items: center;
    gap: 6px;
    height: 22px;
    padding: 0 8px;
    border-radius: var(--radius-sm);
    font-size: var(--font-size-sm);
    line-height: 1;
  }

  .scope-hint {
    border: none;
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
    -webkit-appearance: none;
    appearance: none;
  }

  .scope-hint:hover:not(:disabled) {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  /* The Space picker of a tab move has no scope. */
  .scope-hint:disabled {
    cursor: default;
    opacity: var(--disabled-opacity);
  }

  .scope-hint.selected,
  .scope-token {
    background: var(--accent-tint-14);
    color: var(--accent-ink);
  }

  .scope-hint:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* One slot for every prefix, so the labels line up whatever the glyph. */
  .scope-hint-prefix {
    display: inline-block;
    width: 1em;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    text-align: center;
  }

  .scope-hint.selected .scope-hint-prefix {
    color: inherit;
  }

  .command-bar-results {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    overscroll-behavior: contain;
    padding: 0 8px 8px;
  }

  .command-bar-section-header {
    display: flex;
    align-items: baseline;
    gap: 8px;
    padding: 14px 8px 6px;
  }

  .command-bar-section:first-child .command-bar-section-header {
    padding-top: 12px;
  }

  .command-bar-section-title {
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .command-bar-section-subtitle {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .command-bar-result {
    display: grid;
    /* The helper shows whole while the title keeps its room, then gives way first. */
    grid-template-columns: 24px minmax(min(160px, 50%), 1fr) minmax(0, max-content);
    align-items: center;
    gap: 12px;
    height: 40px;
    padding: 0 8px;
    border-radius: var(--radius-md);
    cursor: pointer;
  }

  .command-bar-result.selected,
  .command-bar-chip.selected {
    background: var(--bg-hover);
  }

  .result-icon {
    position: relative;
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .result-icon-glyph {
    font-size: var(--font-size-lg);
  }

  .result-icon-terminal {
    background: var(--terminal-tile-bg);
    box-shadow: inset 0 0 0 1px var(--terminal-tile-border);
    color: var(--terminal-tile-text);
  }

  /* A site without a favicon: its domain's letter on the domain's own hue. */
  .result-icon-site {
    background: hsl(var(--site-hue) 62% 90%);
    color: hsl(var(--site-hue) 45% 28%);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
  }

  .result-icon-site:has(> img:not([hidden])) {
    background: var(--bg-hover);
  }

  /* The letter waits for a failed load: a favicon with transparent parts would show it through. */
  .result-icon-site:has(> img:not([hidden])) .result-favicon-fallback {
    visibility: hidden;
  }

  .result-favicon-fallback {
    grid-area: 1 / 1;
  }

  .result-favicon-image {
    grid-area: 1 / 1;
    width: 16px;
    height: 16px;
    object-fit: contain;
    border-radius: var(--radius-xs);
  }

  /* Your action is awaited: the orange dot on the icon, as on its tab row. */
  .result-icon-dot {
    position: absolute;
    top: -2px;
    right: -2px;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--float-surface);
  }

  /* The address follows the title on its line, and gives way to it. */
  .result-main {
    display: flex;
    align-items: baseline;
    gap: 8px;
    min-width: 0;
  }

  .result-title {
    flex: none;
    max-width: 70%;
  }

  .result-subtitle {
    flex: 1;
  }

  .result-title,
  .result-subtitle,
  .result-helper,
  .chip-title {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .result-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    line-height: 18px;
  }

  .result-subtitle,
  .result-helper {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 16px;
  }

  .result-hl {
    background: transparent;
    color: var(--accent-ink);
    font-weight: var(--font-weight-semibold);
  }

  .command-bar-strip {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
  }

  .command-bar-chip {
    display: flex;
    align-items: center;
    gap: 8px;
    max-width: 180px;
    height: 32px;
    padding: 0 10px 0 8px;
    border-radius: var(--radius-md);
    cursor: pointer;
  }

  .command-bar-chip .result-icon {
    flex: none;
    width: 20px;
    height: 20px;
    border-radius: var(--radius-xs);
    font-size: var(--font-size-xs);
  }

  .chip-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
  }

  .command-bar-empty {
    display: grid;
    gap: 4px;
    padding: 24px 16px;
    text-align: center;
  }

  .command-bar-empty-title {
    margin: 0;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .command-bar-empty-subtitle {
    max-width: 40ch;
    margin: 0 auto;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .command-bar-footer {
    display: flex;
    flex: none;
    align-items: center;
    gap: 16px;
    height: 36px;
    padding: 0 16px;
    border-top: 1px solid var(--separator);
  }

  /* A hint that does not fit wraps onto a hidden second line: it drops whole, and Esc keeps its place. */
  .footer-hints {
    display: flex;
    flex: 1;
    flex-wrap: wrap;
    gap: 0 16px;
    height: 20px;
    min-width: 0;
    overflow: hidden;
  }

  .key-hint {
    display: inline-flex;
    flex: none;
    align-items: center;
    gap: 6px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    white-space: nowrap;
  }

  .key-hint-default {
    color: var(--text-primary);
  }

  kbd {
    box-sizing: border-box;
    min-width: 20px;
    height: 20px;
    padding: 0 6px;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    box-shadow: inset 0 0 0 1px var(--float-border);
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
    line-height: 20px;
    text-align: center;
  }

  @keyframes command-bar-in {
    from {
      opacity: 0;
      transform: scale(0.96);
    }
  }

  @media (prefers-color-scheme: dark) {
    .result-icon-site {
      background: hsl(var(--site-hue) 40% 30%);
      color: hsl(var(--site-hue) 70% 92%);
    }
  }

  @media (max-width: 640px) {
    .command-bar-backdrop {
      padding: 12px 8px 8px;
    }

    .command-bar-footer,
    .result-helper {
      display: none;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .command-bar {
      animation: command-bar-fade 150ms ease;
      transition: none;
    }

    @keyframes command-bar-fade {
      from {
        opacity: 0;
      }
    }
  }
</style>
