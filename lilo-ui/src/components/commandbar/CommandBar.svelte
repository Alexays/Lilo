<script lang="ts">
  import { portal } from "../../lib/actions/portal";
  import { dismissable } from "../../lib/actions/dismissable";
  import CommandScopePicker from "./CommandScopePicker.svelte";
  import { untrack } from "svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { t } from "../../lib/i18n/state.svelte";
  import { formatShortcut, parseInput, scopePrefix, setTopLevelDomains, type CommandScope } from "../../lib/inputParser";
  import { TOP_LEVEL_DOMAINS } from "../../lib/topLevelDomains.gen";
  import { fade } from "svelte/transition";
  import {
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
    getStoredFavicons,
    cancelMoveTab,
    isCommandBarDocked,
    isCommandBarOpen,
    isNewTabCommandBar,
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

  interface Props {
    /** Escape on a bar in place (docked), once there is no scope or move left to leave: a window that is only the bar closes with it. */
    onEscape?: () => void;
    /** The scope chips offered; all of them by default. */
    scopes?: CommandScope[];
    /** What the field and the empty list say before anything is typed, for a bar that does not search tabs and actions. */
    copy?: { placeholder: string; emptyTitle: string; emptySubtitle: string };
  }
  let { onEscape, scopes, copy }: Props = $props();

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
    SCOPE_HINTS.filter((hint) => scopes ? scopes.includes(hint.scope) : hint.scope !== "terminal" || getSetting("terminalEnabled", "true") !== "false").map(
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

  let detailsOpen = $state(false);
  let helpPosition = $state({ right: 16, top: 0 });
  function showDetails() {
    if (!detailsButton) return;
    const rect = detailsButton.getBoundingClientRect();
    helpPosition = { right: Math.max(16, window.innerWidth - rect.right), top: rect.bottom + 8 };
    detailsOpen = true;
  }
  let detailsButton: HTMLButtonElement | undefined = $state();
  // The hints cover the results: typing puts them away.
  $effect(() => {
    void getCommandBarOpenRequestId();
    void isCommandBarOpen();
    void getQuery();
    detailsOpen = false;
  });

  const commandBarOpen = $derived(isCommandBarOpen());
  const docked = $derived(isCommandBarDocked());
  // In place on a blank tab, the bar steps aside for a screen that covers the page.
  const shown = $derived(
    commandBarOpen &&
      !(docked && (isSettingsShellOpen() || isHistoryShellOpen() || isDesignSystemShellOpen() || getOnboarding().visible)),
  );
  const activeScope = $derived(getActiveScope());
  const query = $derived(getQuery());
  // A typed scope prefix leaves the field for the scope picker; the query keeps it.
  const tokenPrefix = $derived(
    activeScope !== "all" && !isMovingTab() && query.trimStart().startsWith(scopePrefix(activeScope)) ? scopePrefix(activeScope) : "",
  );
  const fieldText = $derived(tokenPrefix ? query.trimStart().slice(tokenPrefix.length).trimStart() : query);
  const tokenLabel = $derived(tokenPrefix ? SCOPE_HINTS.find((hint) => hint.scope === activeScope)?.labelKey : undefined);
  // What was typed past the scope prefix: a bare prefix is an empty scope, not a search.
  const scopedQuery = $derived(parseInput(query, activeScope).query.trim());
  const results = $derived(getResults());
  const sections = $derived(getSections());
  const canSearchWeb = $derived(
    scopedQuery.length > 0 && ["tab", "bookmark", "history"].includes(activeScope) &&
      results.every((result) => result.kind === "showAllHistory"),
  );
  const selectedIndex = $derived(getSelectedIndex());
  const selectedResult = $derived(getSelectedResult());
  const selectedKeys = $derived(getSelectedResultKeys());
  const primaryActionLabel = $derived.by(() => {
    const result = selectedResult;
    const opensURL = result?.url && ["navigate", "search", "history", "bookmark"].includes(result.kind) &&
      !(result.kind === "bookmark" && typeof result.payload.tabId === "string");
    if (opensURL) return isNewTabCommandBar() ? t("historyPage.openInNewTab") : t("common.open");
    return result?.hint || t("common.open");
  });
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
    void shown;
    return untrack(() => buildTabFaviconLookup(getTabs()));
  });

  let commandBarEl: HTMLDivElement | undefined = $state();
  let commandBarContentEl: HTMLDivElement | undefined = $state();
  let inputEl: HTMLInputElement | undefined = $state();

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
    const idx = selectedIndex;
    if (!commandBarOpen) return;
    commandBarContentEl
      ?.querySelector<HTMLElement>(`#cb-result-${idx}`)
      ?.scrollIntoView({ block: "nearest" });
  });

  // The backdrop leaves the sidebar uncovered, so clicks there never reach it: dismiss on any
  // pointerdown outside the panel (the sidebar click itself still goes through, no preventDefault).
  $effect(() => {
    if (!commandBarOpen || docked) {
      return;
    }

    const handleWindowPointerDown = (event: PointerEvent) => {
      const target = event.target as Element | null;
      // Portaled menus and help still belong to the bar's interaction surface.
      if (target?.closest("[data-command-bar-popover]")) return;
      if (commandBarEl && target && !commandBarEl.contains(target)) {
        closeCommandBar();
        // The backdrop catches page clicks; sidebar controls keep their native click focus.
        if (target.classList.contains("command-bar-backdrop")) postMessage("focusPage");
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
    // IME confirmation can report keyCode 229 even after composition ends.
    if (e.isComposing || e.keyCode === 229) return;
    if (detailsOpen && e.key === "Escape") {
      e.preventDefault();
      detailsOpen = false;
      detailsButton?.focus();
      return;
    }
    // Buttons keep their native keyboard activation and focus navigation.
    if (e.target !== inputEl && e.key !== "Escape") return;
    // Tab moves focus as usual, unless it takes the inline completion.
    if (e.key === "Tab" && (e.shiftKey || !autocompleteSuggestion)) return;
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
        } else {
          onEscape?.();
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
        if (completionShown) {
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
        if (caretAtEnd) setQuery(autocompleteSuggestion);
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
        return copy?.placeholder ?? t("commandBar.placeholderAll");
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
        return copy?.emptyTitle ?? t("commandBar.emptyTitleAll");
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
        return copy?.emptySubtitle ?? t("commandBar.emptySubtitleAll");
    }
  }
</script>

<!-- Single line: whitespace inside would render between the highlight segments. -->
{#snippet highlightedText(text: string, highlights?: number[])}{#each segments(text, highlights) as seg, segIndex (`${seg.text}-${seg.highlighted ? '1' : '0'}-${segIndex}`)}{#if seg.highlighted}<mark class="result-hl">{seg.text}</mark>{:else}{seg.text}{/if}{/each}{/snippet}

{#snippet resultIcon(result: CommandResult)}
  {@const iconSpec = resolveResultIcon(result, tabFavicons, getStoredFavicons())}
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
            <CommandScopePicker
              hints={scopeHints}
              active={activeScope}
              disabled={movingTab}
              onselect={(scope) => {
                setCommandBarScope(scope);
                inputEl?.focus();
              }}
            />
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
                  // A prefix typed first takes over from the token.
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
            <button
              bind:this={detailsButton}
              type="button"
              class="command-bar-info"
              aria-label={t("commandBar.showDetails")}
              title={t("commandBar.showDetails")}
              aria-expanded={detailsOpen}
              aria-controls={detailsOpen ? "cb-hints" : undefined}
              onclick={showDetails}
            >
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
                <circle cx="8" cy="8" r="6" stroke="currentColor" stroke-width="1.3" />
                <path d="M8 7v4M8 4.5v.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
              </svg>
            </button>
          </div>
        </div>

        <div class="command-bar-results-area">
        {#if sections.length > 0}
          <div class="command-bar-results" id="cb-results" role="listbox" aria-label={t("commandBar.resultsLabel")}>
            {#each sections as section (section.id)}
              <div class="command-bar-section" role="group" aria-label={section.title}>
                <div class="command-bar-section-header" aria-hidden="true">
                  <span class="command-bar-section-title">{section.title}</span>
                  {#if section.subtitle}<span class="command-bar-section-subtitle">{section.subtitle}</span>{/if}
                </div>

                <div class="command-bar-section-results">
                  {#each section.items as entry (entry.result.id)}
                    {@const subtitle = detail(entry.result)}
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
                      {@render resultIcon(entry.result)}
                      <div class="result-main">
                        <span class="result-title" title={entry.result.title}>{@render highlightedText(entry.result.title, entry.result.titleHighlights)}</span>
                        {#if subtitle.text}
                          <span class="result-subtitle" title={subtitle.text}>{@render highlightedText(subtitle.text, subtitle.highlights)}</span>
                        {/if}
                      </div>

                      {#if entry.result.kind === "action" && entry.result.helper}
                        <kbd class="keycap result-shortcut">{entry.result.helper}</kbd>
                      {:else if entry.index === selectedIndex}
                        <span class="result-action" title={primaryActionLabel} aria-hidden="true">
                          <span class="result-action-label">{primaryActionLabel}</span>
                          <kbd class="keycap">{formatShortcut("Enter")}</kbd>
                        </span>
                      {:else if entry.result.helper}
                        <span class="result-helper">{entry.result.helper}</span>
                      {/if}
                    </div>
                  {/each}
                </div>
              </div>
            {/each}
          </div>
        {:else if scopedQuery || activeScope !== "all"}
          <div class="command-bar-empty">
            <p class="command-bar-empty-title">{emptyStateTitle()}</p>
            <p class="command-bar-empty-subtitle">{emptyStateSubtitle()}</p>
          </div>
        {/if}

        {#if canSearchWeb}
          <div class="command-bar-search-fallback">
            <button type="button" class="web-search-button" onclick={executeRawQuery}>
              {t("commandBar.sectionSearchWeb")}
            </button>
          </div>
        {/if}
        </div>
      </div>
    </div>
  </div>
  {#if detailsOpen}
    <div
      id="cb-hints"
      class="command-bar-help float-surface float-popover"
      data-command-bar-popover
      role="status"
      aria-label={t("commandBar.showDetails")}
      style:right="{helpPosition.right}px"
      style:top="{helpPosition.top}px"
      style:max-height="calc(100dvh - {helpPosition.top + 8}px)"
      use:portal
      use:reportInteractiveZone={{ id: "command-bar-help" }}
      {@attach dismissable({ onDismiss: () => (detailsOpen = false), ignore: ".command-bar-info" })}
    >
      {#if autocompleteSuggestion && caretAtEnd}
        <span class="key-hint"><span>{t("commandBar.hintComplete")}</span><kbd class="keycap">tab</kbd></span>
      {/if}
      <span class="key-hint key-hint-default"><span>{primaryActionLabel}</span><kbd class="keycap">{formatShortcut("Enter")}</kbd></span>
      {#each selectedKeys as key (key)}
        <span class="key-hint">
          <span>{t(key === "newTab" && activeScope === "terminal" ? "commandBar.hintSplit" : RESULT_KEY_HINTS[key].labelKey)}</span><kbd class="keycap">{formatShortcut(RESULT_KEY_HINTS[key].keys)}</kbd>
        </span>
      {/each}
      {#if !docked || movingTab || escapeLeavesScope || onEscape}
        <span class="key-hint"><span>{t(movingTab || escapeLeavesScope ? "common.back" : "common.close")}</span><kbd class="keycap">esc</kbd></span>
      {/if}
    </div>
  {/if}
{/if}

<style>
  /* A quiet tint distinguishes the floating bar while the current page remains visible. */
  .command-bar-backdrop {
    --bar-top: clamp(24px, 18vh, 180px);
    position: fixed;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: var(--bar-top) 16px 16px;
    z-index: 60;
    pointer-events: auto;
  }

  .command-bar-backdrop:not(.docked) {
    background: color-mix(in srgb, var(--chrome-overlay-backdrop-tint) 50%, transparent);
  }

  @media (max-height: 520px) {
    .command-bar-backdrop { --bar-top: 24px; }
  }

  /* One height whatever the results, so typing never moves the panel. */
  .command-bar {
    width: min(480px, 100%);
    height: min(320px, calc(100dvh - var(--bar-top) - 80px));
    max-height: 100%;
    border: 1px solid var(--float-border);
    border-radius: var(--radius-lg);
    overflow: hidden;
    display: flex;
    flex-direction: column;
    transform-origin: 50% 0;
    animation: command-bar-in var(--motion-duration-overlay) var(--motion-ease-spring);
    contain: layout style;
    background: linear-gradient(160deg, var(--float-sheen), transparent 48%), var(--float-surface);
    box-shadow: inset 0 1px 0 var(--float-sheen), var(--float-shadow);
  }

  /* Part of the page rather than over it: no shadow to lift it. */
  .docked .command-bar {
    box-shadow: inset 0 1px 0 var(--float-sheen);
    animation: none;
  }

  .command-bar-help {
    position: fixed;
    z-index: var(--z-popover);
    gap: 12px;
    width: min(360px, calc(100vw - 32px));
    padding: 12px 16px;
    overflow-y: auto;
  }

  .command-bar-info {
    display: grid;
    place-items: center;
    flex: none;
    width: 28px;
    height: 28px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
  }
  .command-bar-info:hover { background: var(--bg-hover); }
  .command-bar-info:focus-visible { outline: var(--focus-outline); }

  .command-bar-content {
    container: command-bar / inline-size;
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    min-height: 0;
  }

  .command-bar-header {
    flex: none;
  }

  .command-bar-input-row {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 56px;
    padding: 0 16px;
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

  .command-bar-results-area {
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    min-height: 0;
    border-top: 1px solid var(--separator);
  }

  .command-bar-results,
  .command-bar-help { scrollbar-gutter: stable; }

  .command-bar-results::-webkit-scrollbar,
  .command-bar-help::-webkit-scrollbar { width: 8px; background: transparent; }

  .command-bar-results::-webkit-scrollbar-thumb,
  .command-bar-help::-webkit-scrollbar-thumb {
    background: color-mix(in srgb, var(--text-secondary) 32%, transparent);
    border: 2px solid transparent;
    border-radius: var(--radius-chip);
    background-clip: padding-box;
  }

  .command-bar-results::-webkit-scrollbar-thumb:hover,
  .command-bar-help::-webkit-scrollbar-thumb:hover {
    background-color: color-mix(in srgb, var(--text-secondary) 55%, transparent);
  }

  .command-bar-results {
    overflow-x: hidden;
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
    padding: 8px 8px 6px;
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
    gap: 8px;
    min-height: 48px;
    padding: 6px 8px;
    border-radius: var(--radius-md);
    cursor: pointer;
  }

  .command-bar-result.selected {
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

  .result-action {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    max-width: 160px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .result-action-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .command-bar-search-fallback {
    flex: none;
    padding: 8px 16px 16px;
    text-align: center;
  }

  .web-search-button {
    min-height: 28px;
    max-width: 100%;
    padding: 4px 12px;
    border: none;
    border-radius: var(--radius-sm);
    background: var(--accent);
    color: var(--accent-text);
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .web-search-button:hover {
    background: var(--accent-hover);
  }

  .web-search-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  /* The address sits under the title. */
  .result-main {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }

  .result-title,
  .result-subtitle,
  .result-helper {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .result-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    line-height: max(18px, 1.3em);
  }

  .result-subtitle,
  .result-helper {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: max(16px, 1.3em);
  }

  .result-hl {
    background: transparent;
    color: var(--accent-ink);
    font-weight: var(--font-weight-semibold);
  }

  .command-bar-empty {
    display: grid;
    gap: 4px;
    padding: 24px 16px;
    overflow-y: auto;
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

  @container command-bar (max-width: 440px) {
    .command-bar-result { grid-template-columns: 24px minmax(0, 1fr) minmax(0, 32%); }
    .command-bar-input-row { gap: 8px; }
  }

  @container command-bar (max-width: 340px) {
    .result-action-label { display: none; }
    .command-bar-result { grid-template-columns: 24px minmax(0, 1fr) auto; }
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
      padding: var(--bar-top) 8px 8px;
    }

    .result-helper {
      display: none;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .command-bar {
      animation: command-bar-fade 150ms ease !important;
    }

    @keyframes command-bar-fade {
      from {
        opacity: 0;
      }
    }
  }
</style>
