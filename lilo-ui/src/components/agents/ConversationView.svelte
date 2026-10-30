<script lang="ts" module>
  import type { IconName } from "./icons";

  const SUGGESTIONS: { key: string; icon: IconName }[] = [
    { key: "explain", icon: "book" },
    { key: "fixBug", icon: "bug" },
    { key: "tests", icon: "flask" },
  ];
</script>

<script lang="ts">
  import { modeIcon, modelLogo } from "./modelLogos";
  import "../../lib/i18n/agentsCatalog";
  import { untrack } from "svelte";
  import { cubicOut } from "svelte/easing";
  import { fade } from "svelte/transition";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { conversationActions } from "./conversationActions";
  import type { BridgeSplitPaneFrame } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { restingFly } from "../../lib/motion/restingTransitions";
  import { springEase } from "../../lib/motion/spring";
  import { MOTION } from "../../lib/motion/timings";
  import { tooltip } from "../../lib/tooltip";
  import {
    addLocalPrompt,
    getAgent,
    getConversationState,
    getConversationSummary,
    getConversationVersion,
    getOpenConversation,
    hideConversation,
    showConversation,
  } from "../../stores/conversations.svelte";
  import { getSplitPanes } from "../../stores/splitPanes.svelte";
  import { getTabsById, tabDisplayTitle } from "../../stores/tabs.svelte";
  import AgentTile from "./AgentTile.svelte";
  import type { ImageRef, PermissionItem, ThreadItem, ToolCallItem } from "./conversationModel";
  import Icon from "./Icon.svelte";
  import Lightbox from "./Lightbox.svelte";
  import MenuPicker from "./MenuPicker.svelte";
  import PromptField, { type AttachmentDraft } from "./PromptField.svelte";
  import ThreadRow, { type TurnSummary } from "./ThreadRow.svelte";
  import { formatDuration, itemSignature } from "./threadView";
  import WorkBlock from "./WorkBlock.svelte";

  interface Props {
    tabId: string;
    /** The pane's frame as shares of the content area. */
    frame: Pick<BridgeSplitPaneFrame, "x" | "y" | "width" | "height">;
  }

  let { tabId, frame }: Props = $props();

  type ItemRow = { kind: "item"; key: string; item: ThreadItem; sig: string; promptIndex: number; canRestore: boolean; turn: TurnSummary | null };
  type WorkRow = { kind: "work"; key: string; calls: ToolCallItem[]; sig: string; promptIndex: number; done: boolean };
  /** A prompt and everything that answers it. */
  type Turn = { key: string; rows: (ItemRow | WorkRow)[] };

  // Long threads draw only their tail; "Show earlier" reveals more.
  const PAGE = 200;
  const PIN_SLACK = 40;
  // The thread's top padding, and the room it keeps above the floating composer.
  const PAD_TOP = 24;
  const DOCK_GAP = 32;

  $effect(() => {
    const id = tabId;
    showConversation(id);
    return () => hideConversation(id);
  });

  const version = $derived(getConversationVersion());
  const conversation = $derived.by(() => {
    void version;
    return getOpenConversation(tabId);
  });
  const agentState = $derived(getConversationState(tabId));
  const busy = $derived(agentState === "busy" || agentState === "starting");
  // Set on send, so the status line shows on that frame rather than when Lilo reports the turn.
  let sentPending = $state(false);
  $effect(() => {
    void agentState;
    untrack(() => (sentPending = false));
  });
  const working = $derived(busy || sentPending);
  const tab = $derived(getTabsById().get(tabId));

  let limit = $state(PAGE);
  let text = $state("");
  let attachments = $state.raw<AttachmentDraft[]>([]);
  let threadEl: HTMLDivElement | undefined = $state();
  let columnEl: HTMLDivElement | undefined = $state();
  let elapsedEl: HTMLSpanElement | undefined = $state();
  let threadHeight = $state(0);
  let composerHeight = $state(0);
  let field: ReturnType<typeof PromptField> | undefined = $state();
  let lightbox = $state.raw<{ images: ImageRef[]; start: number; opener: HTMLElement } | null>(null);

  // Thumbnails mark themselves `data-lightbox`: one listener here, and the viewer steps through what the thread draws.
  function openLightbox(event: MouseEvent): void {
    const opener = (event.target as Element).closest<HTMLElement>("[data-lightbox]");
    if (!opener || !columnEl) return;
    const imgs = [...columnEl.querySelectorAll<HTMLImageElement>("[data-lightbox] img")];
    const start = imgs.indexOf(opener.querySelector("img") as HTMLImageElement);
    lightbox = { images: imgs.map((img) => ({ src: img.getAttribute("src") ?? "", alt: img.alt })), start: Math.max(0, start), opener };
  }

  /**
   * following: the end stays in view as the reply grows. anchoring: a prompt just sent sits near the top
   * and its reply streams below it, until the reply reaches the composer. free: the reader scrolled up.
   */
  let scrollMode = $state<"following" | "anchoring" | "free">("following");
  let atBottom = $state(true);
  // The turn sent from here keeps a viewport of room below its prompt, so streaming never moves it.
  let anchorKey = $state("");
  let anchorPending = false;
  let glide: { easing: string; duration: number } | null = null;

  const turns = $derived.by((): Turn[] => {
    void version;
    if (!conversation) return [];
    const { items } = conversation.thread;
    const undone = conversation.undone;
    const start = Math.max(0, items.length - limit);
    let prompt = -1;
    for (let i = 0; i < start; i++) if (items[i].kind === "user") prompt++;
    const out: Turn[] = [];
    let turn: Turn | null = null;
    let work: WorkRow | null = null;
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- local to one run, only its size is kept
    let files = new Set<string>();
    let added = 0;
    let removed = 0;
    let finalText = "";
    for (let i = start; i < items.length; i++) {
      const item = items[i];
      if (item.kind === "user") {
        prompt++;
        turn = null;
        files = new Set();
        added = removed = 0;
        finalText = "";
      }
      if (!turn) {
        turn = { key: `t${item.id}`, rows: [] };
        out.push(turn);
      }
      if (item.kind === "toolCall") {
        for (const diff of item.diffs) {
          files.add(diff.path);
          added += diff.added;
          removed += diff.removed;
        }
        const sig = itemSignature(item, undone);
        if (work) {
          work.calls.push(item);
          work.sig += `|${sig}`;
        } else {
          // Keyed by its first call: the block grows in place as calls arrive.
          work = { kind: "work", key: `w${item.id}`, calls: [item], sig, promptIndex: prompt, done: false };
          turn.rows.push(work);
        }
        continue;
      }
      work = null;
      if (item.kind === "agent") finalText = item.text;
      if (item.kind === "turnEnd") for (const row of turn.rows) if (row.kind === "work") row.done = true;
      turn.rows.push({
        kind: "item",
        key: `i${item.id}`,
        item,
        sig: itemSignature(item, undone),
        promptIndex: prompt,
        canRestore: item.kind === "user" && conversation.checkpoints[prompt] === true,
        turn: item.kind === "turnEnd" ? { files: files.size, added, removed, finalText } : null,
      });
    }
    // A turn that stopped without its end (an error, an agent that quit) folds its work too.
    if (!working) for (const row of out.at(-1)?.rows ?? []) if (row.kind === "work") row.done = true;
    return out;
  });
  const empty = $derived(conversation !== undefined && turns.length === 0);
  const hiddenCount = $derived.by(() => {
    void version;
    return Math.max(0, (conversation?.thread.items.length ?? 0) - limit);
  });
  const reserve = $derived(Math.max(0, threadHeight - PAD_TOP - composerHeight - DOCK_GAP));

  const header = $derived.by(() => {
    void version;
    const thread = conversation?.thread;
    const cwd = conversation?.cwd ?? "";
    const modes = conversation?.modes ?? [];
    // The model, and the mode when the agent has no session modes, get their own picker; the rest
    // goes in one menu under their names. A mode the agent also lists as an option shows once.
    const options = (thread?.configOptions ?? []).filter(
      (config) => config.options.length > 1 && !(config.category === "mode" && modes.length > 1),
    );
    const configs = options.filter((config) => config.category === "model" || (config.category === "mode" && modes.length <= 1));
    const extraConfigs = options.filter((config) => !configs.includes(config));
    const agentId = conversation?.agentId ?? tab?.agentId ?? "";
    return {
      title: thread?.title || getConversationSummary(tabId)?.title || tabDisplayTitle(tab?.title ?? ""),
      agentId,
      agentName: getAgent(agentId)?.name || agentId,
      project: cwd.split("/").filter(Boolean).pop() ?? "",
      cwd,
      ownCopy: cwd.includes("/Worktrees/"),
      branch: tab?.gitBranch ?? "",
      modes,
      extraConfigs,
      modeId: thread?.modeId ?? "",
      configs,
      usage: thread?.usage && thread.usage.size > 0 ? thread.usage : null,
      queued: conversation?.queued ?? 0,
      error: conversation?.error ?? null,
      authMethods: conversation?.authMethods ?? [],
      commands: thread?.commands ?? [],
    };
  });
  const usagePercent = $derived(header.usage ? Math.min(100, Math.round((header.usage.used / header.usage.size) * 100)) : 0);
  const hasDraft = $derived(text.trim().length > 0 || attachments.length > 0);
  const stopping = $derived(working && !hasDraft);

  // The web page beside the conversation in a split, for "Selection" and "Screenshot".
  const pageTabId = $derived.by(() => {
    const tabs = getTabsById();
    return getSplitPanes().find((pane) => tabs.get(pane.tabId)?.kind === "web")?.tabId ?? null;
  });

  $effect(() => {
    void turns;
    void composerHeight;
    void threadHeight;
    untrack(settleScroll);
  });

  function settleScroll(): void {
    const el = threadEl;
    if (!el) return;
    const max = el.scrollHeight - el.clientHeight;
    const anchor = anchorPending ? el.querySelector<HTMLElement>(`[data-turn="${anchorKey}"]`) : null;
    anchorPending = false;
    if (anchor) return glideTo(el, Math.min(anchor.offsetTop - PAD_TOP, max));
    if (scrollMode === "anchoring" && max > el.scrollTop + 2) scrollMode = "following";
    if (scrollMode === "following") scrollTo(el, max);
  }

  /** Where Lilo itself last scrolled the thread: the scroll event that follows is not the reader's. */
  let ownScrollTop = -1;

  function scrollTo(el: HTMLElement, top: number): void {
    el.scrollTop = top;
    ownScrollTop = el.scrollTop;
  }

  // The jump is instant, so no scroll event lands mid-way; the column glides from where it was, on the compositor.
  function glideTo(el: HTMLElement, to: number): void {
    const shift = Math.max(-el.clientHeight / 2, Math.min(el.clientHeight / 2, to - el.scrollTop));
    scrollTo(el, to);
    if (!columnEl || Math.abs(shift) < 2 || prefersReducedMotion()) return;
    if (!glide) {
      const style = getComputedStyle(columnEl);
      glide = {
        easing: style.getPropertyValue("--motion-ease-organic").trim() || "ease-out",
        duration: parseFloat(style.getPropertyValue("--motion-duration-slow")) || 280,
      };
    }
    columnEl.animate([{ transform: `translateY(${shift}px)` }, { transform: "none" }], glide);
  }

  // Lilo only ever scrolls to the end or to an anchored prompt, so landing anywhere else is the reader scrolling.
  function onThreadScroll(): void {
    if (!threadEl) return;
    const bottom = threadEl.scrollHeight - threadEl.scrollTop - threadEl.clientHeight < PIN_SLACK;
    if (bottom !== atBottom) atBottom = bottom;
    if (Math.abs(threadEl.scrollTop - ownScrollTop) < 2) return;
    if (bottom && scrollMode === "free") scrollMode = "following";
    else if (!bottom && scrollMode !== "free") scrollMode = "free";
  }

  function jumpToLatest(): void {
    if (!threadEl) return;
    scrollMode = "following";
    glideTo(threadEl, threadEl.scrollHeight - threadEl.clientHeight);
  }

  // One timer, only while a turn runs: it writes the text in place instead of re-rendering.
  $effect(() => {
    const el = elapsedEl;
    if (!working || !el) return;
    const fallback = Date.now();
    const tick = () => {
      el.textContent = formatDuration(Date.now() - (getOpenConversation(tabId)?.thread.turnStartedAt ?? fallback));
    };
    tick();
    const timer = setInterval(tick, 1000);
    return () => clearInterval(timer);
  });

  const ready = $derived(conversation !== undefined);
  // The replayed history draws still; only items arriving after it rise in.
  let live = $state(false);
  $effect(() => {
    if (!ready) return;
    requestAnimationFrame(() => {
      live = true;
      field?.focus();
    });
  });

  const asking = $derived.by(() => {
    void version;
    return pendingPermission() !== null;
  });

  function pendingPermission(): PermissionItem | null {
    const items = conversation?.thread.items ?? [];
    for (let i = items.length - 1; i >= 0; i--) {
      const item = items[i];
      if (item.kind === "permission" && item.answer === null) return item;
    }
    return null;
  }

  function send(interrupt: boolean): void {
    const prompt = text.trim();
    if (!prompt && attachments.length === 0) return;
    const sent = attachments;
    conversationActions.send({
      tabId,
      text: prompt,
      attachments: sent.map((draft) => draft.attachment),
      interrupt: interrupt && busy,
    });
    text = "";
    attachments = [];
    sentPending = true;
    const id = addLocalPrompt(tabId, prompt, sent.map((draft) => ({ label: draft.label, uri: "" })));
    if (id === null) return;
    anchorKey = `t${id}`;
    anchorPending = true;
    scrollMode = "anchoring";
  }

  function stop(): boolean {
    if (!working) return false;
    conversationActions.cancel(tabId);
    return true;
  }

  function answerPending(allow: boolean): boolean {
    const permission = pendingPermission();
    if (!permission) return false;
    const option = allow
      ? permission.options.find((candidate) => candidate.kind === "allow_once") ?? permission.options.find((candidate) => candidate.kind === "allow_always")
      : permission.options.find((candidate) => candidate.kind === "reject_once") ?? permission.options.find((candidate) => candidate.kind === "reject_always");
    if (allow && !option) return false;
    conversationActions.answer(tabId, String(permission.requestId), option?.optionId);
    return true;
  }
</script>

<div class="conversation-root chrome-content-overlay-root">
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <section
    class="conversation"
    style:left="{frame.x * 100}%"
    style:top="{frame.y * 100}%"
    style:width="{frame.width * 100}%"
    style:height="{frame.height * 100}%"
    aria-label={header.title}
    use:reportInteractiveZone={{ id: `conversation-${tabId}` }}
    onkeydown={(event) => {
      if (event.metaKey && event.key === "." && stop()) event.preventDefault();
    }}
  >
    <header class="header">
      <AgentTile agentId={header.agentId} />
      <h1 class="title">{header.title}</h1>
      {#if header.project}
        <span class="chip" use:tooltip={header.cwd}>
          <Icon name="folder" size={12} />
          {header.project}
        </span>
      {/if}
      {#if header.branch}
        <span class="chip" use:tooltip={t("agents.conversation.branch", { branch: header.branch })}>
          <Icon name="branch" size={12} />
          <span class="chip-text">{header.branch}</span>
        </span>
      {/if}
      {#if header.ownCopy}
        <span class="chip own-copy" use:tooltip={t("agents.conversation.ownCopyHint")}>
          <Icon name="copy" size={12} />
          {t("agents.conversation.ownCopy")}
        </span>
      {/if}
      <span class="spacer"></span>
      {#if header.usage}
        <span
          class="gauge"
          in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}
          role="img"
          aria-label={t("agents.conversation.context", { percent: usagePercent })}
          use:tooltip={t("agents.conversation.context", { percent: usagePercent })}
        >
          <span class="ring" style:--context-used="{usagePercent}%"></span>
          {usagePercent}%
        </span>
      {/if}
    </header>

    <div
      class="thread"
      bind:this={threadEl}
      bind:clientHeight={threadHeight}
      style:padding-top="{PAD_TOP}px"
      style:padding-bottom="{composerHeight + DOCK_GAP}px"
      onscroll={onThreadScroll}
    >
      <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
      <div class="column" bind:this={columnEl} onclick={openLightbox}>
        {#if hiddenCount > 0}
          <button type="button" class="show-earlier" onclick={() => (limit += PAGE)}>
            {t("agents.conversation.showEarlier", { count: hiddenCount })}
          </button>
        {/if}
        {#if empty}
          <div class="hero" style:min-height="{reserve}px" in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}>
            <span class="hero-tile"><AgentTile agentId={header.agentId} /></span>
            <h2 class="hero-name">{header.agentName}</h2>
            {#if header.project}
              <span class="hero-project"><Icon name="folder" size={13} />{header.project}</span>
            {/if}
            {#if agentState === "starting"}
              <span class="hero-status">{t("agents.conversation.starting")}</span>
            {/if}
            <div class="suggestions">
              {#each SUGGESTIONS as suggestion (suggestion.key)}
                <button
                  type="button"
                  class="suggestion"
                  onclick={() => {
                    text = t(`agents.empty.suggestions.${suggestion.key}.prompt`);
                    field?.focus();
                  }}
                >
                  <Icon name={suggestion.icon} size={14} />
                  {t(`agents.empty.suggestions.${suggestion.key}.label`)}
                </button>
              {/each}
            </div>
          </div>
        {/if}
        {#each turns as turn, turnIndex (turn.key)}
          <div class="turn" data-turn={turn.key} style:min-height={turn.key === anchorKey ? `${reserve}px` : undefined}>
            {#each turn.rows as row (row.key)}
              {@const permission = row.kind === "item" && row.item.kind === "permission"}
              <div
                class="row"
                in:restingFly={{
                  duration: live && !prefersReducedMotion() ? MOTION.itemEnterMs + (permission ? 120 : 0) : 0,
                  easing: permission ? springEase : cubicOut,
                  x: 0,
                  y: permission ? 10 : 6,
                }}
              >
                {#if row.kind === "work"}
                  <WorkBlock
                    {tabId}
                    calls={row.calls}
                    sig={row.sig}
                    done={row.done}
                    {live}
                    cwd={header.cwd}
                    promptIndex={row.promptIndex}
                    undone={conversation?.undone ?? new Set()}
                  />
                {:else}
                  <ThreadRow
                    {tabId}
                    item={row.item}
                    sig={row.sig}
                    promptIndex={row.promptIndex}
                    canRestore={row.canRestore}
                    turn={row.turn}
                    cwd={header.cwd}
                  />
                {/if}
              </div>
            {/each}
            <!-- Where the reply appears, right under the prompt: what the agent is doing reads where the eye is. -->
            {#if working && turnIndex === turns.length - 1}
              <div class="activity" role="status" in:fade={{ duration: prefersReducedMotion() ? 0 : 120 }}>
                {#if asking}
                  <span class="pip" aria-hidden="true"></span>
                  <span class="status-label">{t("agents.status.waiting")}</span>
                {:else}
                  <span class="dots" aria-hidden="true"><span></span><span></span><span></span></span>
                  <span class="status-label shimmer">{t("agents.status.working")}</span>
                  <span class="elapsed" bind:this={elapsedEl} aria-hidden="true"></span>
                  <span class="status-hint">{t("agents.status.stopHint")}</span>
                {/if}
              </div>
            {/if}
          </div>
        {/each}
        {#if header.error}
          <div
            class="error"
            role="alert"
            in:restingFly={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs, easing: cubicOut, x: 0, y: 6 }}
          >
            <div class="error-title">{header.error}</div>
            {#if header.authMethods.length > 0}
              <div class="error-hint">{t("agents.conversation.signInHint")}</div>
              <div class="sign-in">
                {#each header.authMethods as method (method.id)}
                  <button type="button" title={method.description ?? ""} onclick={() => conversationActions.authenticate(tabId, method.id)}>
                    {method.name}
                  </button>
                {/each}
              </div>
            {:else}
              <div class="error-hint">{t("agents.conversation.errorHint")}</div>
            {/if}
          </div>
        {/if}
      </div>
    </div>

    <div class="dock" bind:clientHeight={composerHeight}>
      <!-- Laid over the thread's bottom padding: showing either never changes the dock's height. -->
      {#if scrollMode === "free" && !atBottom}
        <button
          type="button"
          class="jump"
          transition:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}
          onclick={jumpToLatest}
        >
          <Icon name="arrowDown" size={12} />
          {t("agents.conversation.jumpToLatest")}
        </button>
      {/if}
      {#if header.queued > 0}
        <div class="queue" in:restingFly={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs, easing: cubicOut, x: 0, y: 8 }}>
          <Icon name="queue" size={12} />
          {t("agents.conversation.queued", { count: header.queued })}
          <span class="queue-hint">{t("agents.conversation.queuedHint")}</span>
        </div>
      {/if}
      <div class="composer float-surface">
        <PromptField
          bind:this={field}
          bind:text
          bind:attachments
          placeholder={t("agents.composer.placeholder")}
          ariaLabel={t("agents.composer.label")}
          {pageTabId}
          cwd={header.cwd}
          commands={header.commands}
          onsubmit={send}
          onemptyreturn={() => attachments.length === 0 && answerPending(true)}
          onescape={() => answerPending(false) || stop()}
          onemptyup={() => {
            const items = conversation?.thread.items ?? [];
            for (let i = items.length - 1; i >= 0; i--) {
              const item = items[i];
              if (item.kind !== "user" || !item.text) continue;
              text = item.text;
              return true;
            }
            return false;
          }}
        />
        <div class="composer-bar">
          <button
            type="button"
            class="bar-button"
            aria-label={t("agents.composer.addContext")}
            use:tooltip={t("agents.composer.addContext")}
            onclick={() => field?.startMention()}
          ><Icon name="at" size={14} /></button>
          {#if header.modes.length > 1}
            <MenuPicker
              value={header.modeId}
              options={header.modes.map((mode) => ({ value: mode.id, label: mode.name, detail: mode.description ?? undefined, icon: modeIcon(`${mode.id} ${mode.name}`) }))}
              ariaLabel={t("agents.conversation.mode")}
              onchange={(modeId) => conversationActions.setMode(tabId, modeId)}
            >
              <Icon name={modeIcon(`${header.modeId} ${header.modes.find((mode) => mode.id === header.modeId)?.name ?? ""}`)} size={13} />
              <span class="picker-label">{header.modes.find((mode) => mode.id === header.modeId)?.name ?? ""}</span>
            </MenuPicker>
          {/if}
          {#each header.configs as config (config.id)}
            <MenuPicker
              value={config.currentValue}
              options={config.options.map((option) => ({
                value: option.value,
                label: option.name,
                detail: option.description ?? undefined,
                icon: config.category === "mode" ? modeIcon(`${option.value} ${option.name}`) : "sparkle",
                logo: config.category === "model" ? modelLogo(`${option.value} ${option.name}`) : undefined,
              }))}
              ariaLabel={config.name}
              onchange={(value) => conversationActions.setConfig(tabId, config.id, value)}
            >
              {@const current = config.options.find((option) => option.value === config.currentValue)}
              {@const logo = config.category === "model" ? modelLogo(`${config.currentValue} ${current?.name ?? ""}`) : undefined}
              {#if logo}
                <svg class="model-logo" viewBox="0 0 24 24" aria-hidden="true" style:color={logo.color}><path d={logo.path} /></svg>
              {:else}
                <Icon name={config.category === "mode" ? modeIcon(`${config.currentValue} ${current?.name ?? ""}`) : "sparkle"} size={13} />
              {/if}
              <span class="picker-label">{config.options.find((option) => option.value === config.currentValue)?.name ?? config.name}</span>
            </MenuPicker>
          {/each}
          {#if header.extraConfigs.length > 0}
            <MenuPicker
              value=""
              options={header.extraConfigs.flatMap((config) => config.options.map((option) => ({
                value: `${config.id}\n${option.value}`,
                label: option.name,
                group: config.name,
                checked: option.value === config.currentValue,
                icon: config.category === "thought_level" ? ("brain" as const) : ("sliders" as const),
              })))}
              ariaLabel={t("agents.conversation.moreOptions")}
              onchange={(value) => {
                const [configId, optionValue] = value.split("\n");
                conversationActions.setConfig(tabId, configId, optionValue);
              }}
            >
              <Icon name="sliders" size={14} />
            </MenuPicker>
          {/if}
          <span class="spacer"></span>
          <!-- One button: it stops the turn while one runs with nothing typed, and sends otherwise. -->
          <button
            type="button"
            class="send"
            class:stopping
            disabled={!stopping && !hasDraft}
            aria-label={stopping ? t("agents.conversation.stop") : t("agents.composer.send")}
            use:tooltip={stopping
              ? { text: t("agents.conversation.stop"), shortcut: "⌘." }
              : { text: t("agents.composer.send"), shortcut: working ? "⌘⏎" : undefined }}
            onclick={() => (stopping ? stop() : send(false))}
          >
            <span class="glyph send-glyph"><Icon name="arrowUp" size={14} /></span>
            <span class="glyph stop-glyph"><span></span></span>
          </button>
        </div>
      </div>
    </div>
    {#if lightbox}
      <Lightbox
        images={lightbox.images}
        start={lightbox.start}
        onclose={() => {
          lightbox?.opener.focus();
          lightbox = null;
        }}
      />
    {/if}
  </section>
</div>

<style>
  .model-logo {
    width: 13px;
    height: 13px;
    flex: none;
    fill: currentColor;
  }

  .conversation-root {
    pointer-events: none;
    overflow: hidden;
  }

  .conversation {
    position: absolute;
    display: flex;
    flex-direction: column;
    background: var(--bg-primary);
    color: var(--text-primary);
    border-radius: var(--chrome-overlay-boundary-radius);
    overflow: hidden;
    pointer-events: auto;
  }

  .header {
    flex: none;
    display: flex;
    align-items: center;
    gap: var(--space-8);
    height: 44px;
    padding: 0 var(--space-12) 0 var(--space-16);
    border-bottom: 1px solid var(--separator);
    min-width: 0;
  }

  .title {
    margin: 0 var(--space-2) 0 0;
    min-width: 0;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .chip {
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    max-width: 180px;
    height: 22px;
    padding: 0 var(--space-8);
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-10);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    white-space: nowrap;
  }

  .chip-text {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .chip.own-copy {
    background: color-mix(in srgb, var(--success) 16%, transparent);
    color: var(--success-text);
  }

  .spacer {
    flex: 1;
  }

  .gauge {
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    padding: 0 var(--space-4);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
  }

  /* Registered so the arc can transition: a 14px repaint, only when usage changes. */
  @property --context-used {
    syntax: "<percentage>";
    inherits: false;
    initial-value: 0%;
  }

  .ring {
    width: 14px;
    height: 14px;
    border-radius: var(--radius-chip);
    background: conic-gradient(var(--accent) 0 var(--context-used), var(--text-primary-tint-12) var(--context-used) 100%);
    mask: radial-gradient(circle, transparent 4px, black 4.5px);
    transition: --context-used var(--motion-duration-slow) var(--motion-ease-organic);
  }

  .thread {
    position: relative;
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    overflow-anchor: none;
  }

  .column {
    max-width: 700px;
    margin: 0 auto;
    padding: 0 var(--space-24);
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
  }

  .turn,
  .row {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    min-width: 0;
  }

  .hero {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: var(--space-6);
    text-align: center;
  }

  .hero-tile {
    display: grid;
    place-items: center;
    width: 44px;
    height: 44px;
    margin-bottom: var(--space-6);
  }

  /* The 16px tile drawn at hero size: scaled, so it keeps its exact proportions. */
  .hero-tile :global(.agent-tile) {
    transform: scale(2.5);
  }

  .hero-name {
    margin: 0;
    font-size: var(--font-size-xl);
    font-weight: var(--font-weight-semibold);
  }

  .hero-project {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .hero-status {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .suggestions {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: var(--space-8);
    margin-top: var(--space-16);
  }

  .suggestion {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: var(--control-height-md);
    padding: 0 var(--space-12);
    border: 1px solid var(--border);
    border-radius: var(--radius-chip);
    background: none;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast),
      transform var(--motion-duration-fast) var(--motion-ease-standard);
  }

  .suggestion:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .suggestion:active {
    transform: scale(0.97);
  }

  .show-earlier {
    align-self: center;
    height: var(--control-height-sm);
    padding: 0 var(--space-10);
    border: 1px solid var(--border);
    border-radius: var(--radius-chip);
    background: none;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-xs);
    cursor: pointer;
  }

  .show-earlier:hover {
    background: var(--bg-hover);
  }

  .error {
    padding: var(--space-10) var(--space-12);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--danger) 10%, transparent);
    font-size: var(--font-size-sm);
    overflow-wrap: anywhere;
  }

  .error-title {
    color: var(--danger-text);
    font-weight: var(--font-weight-medium);
  }

  .error-hint {
    margin-top: var(--space-2);
    color: var(--text-secondary);
  }

  .sign-in {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
    margin-top: var(--space-8);
  }

  .sign-in button {
    height: var(--control-height-sm);
    padding: 0 var(--space-10);
    border: none;
    border-radius: var(--radius-sm);
    background: var(--accent);
    color: var(--accent-text);
    font: inherit;
    font-weight: var(--font-weight-medium);
    cursor: pointer;
  }

  .sign-in button:hover {
    background: var(--accent-hover);
  }

  .dock {
    position: absolute;
    left: 50%;
    bottom: var(--space-16);
    transform: translateX(-50%);
    width: min(700px, calc(100% - var(--space-32)));
    display: flex;
    flex-direction: column;
    align-items: center;
  }

  .activity {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-height: 24px;
    margin-top: var(--space-4);
    color: var(--text-secondary);
    font-size: var(--font-size-md);
    white-space: nowrap;
  }

  /* A light passing over the word while the agent works; it runs only while a turn does. */
  .shimmer {
    background: linear-gradient(
      90deg,
      var(--text-secondary) 0%,
      var(--text-secondary) 40%,
      var(--text-primary) 50%,
      var(--text-secondary) 60%,
      var(--text-secondary) 100%
    );
    background-size: 300% 100%;
    background-clip: text;
    -webkit-background-clip: text;
    color: transparent;
    animation: shimmer 1.8s linear infinite;
  }

  @keyframes shimmer {
    from {
      background-position: 100% 0;
    }
    to {
      background-position: 0 0;
    }
  }

  .status-label {
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
  }

  .elapsed {
    color: var(--text-muted);
    font-variant-numeric: tabular-nums;
  }

  .status-hint {
    color: var(--text-muted);
  }

  .status-hint::before {
    content: "\00b7";
    margin-right: var(--space-6);
  }

  .pip {
    width: 7px;
    height: 7px;
    border-radius: var(--radius-chip);
    background: var(--attention);
  }

  .dots {
    display: inline-flex;
    gap: var(--space-2);
  }

  .dots span {
    width: 4px;
    height: 4px;
    border-radius: var(--radius-chip);
    background: var(--agents);
    animation: thinking 1.2s var(--motion-ease-standard) infinite;
  }

  .dots span:nth-child(2) {
    animation-delay: 0.15s;
  }

  .dots span:nth-child(3) {
    animation-delay: 0.3s;
  }

  @keyframes thinking {
    0%,
    60%,
    100% {
      opacity: 0.35;
      transform: translateY(0);
    }

    30% {
      opacity: 1;
      transform: translateY(-2px);
    }
  }

  .jump {
    position: absolute;
    left: 50%;
    bottom: calc(100% + var(--space-6));
    translate: -50% 0;
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: var(--control-height-sm);
    padding: 0 var(--space-10);
    border: 1px solid var(--border);
    border-radius: var(--radius-chip);
    background: var(--bg-elevated);
    box-shadow: var(--shadow-sm);
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-xs);
    cursor: pointer;
  }

  .jump:hover {
    color: var(--text-primary);
  }

  .queue {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    width: calc(100% - 2 * var(--space-20));
    box-sizing: border-box;
    padding: var(--space-6) var(--space-10);
    border: 1px solid var(--border);
    border-bottom: 0;
    border-radius: var(--radius-md) var(--radius-md) 0 0;
    background: var(--bg-secondary);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .queue-hint {
    margin-left: auto;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .composer {
    width: 100%;
    box-sizing: border-box;
    padding: var(--space-10) var(--space-8) var(--space-8) var(--space-12);
    border-radius: var(--radius-lg);
  }

  .composer-bar {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    min-width: 0;
    margin: var(--space-6) 0 0 calc(-1 * var(--space-6));
  }

  .picker-label {
    max-width: 140px;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .bar-button {
    display: grid;
    place-items: center;
    flex: none;
    width: var(--control-height-sm);
    height: var(--control-height-sm);
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
    cursor: pointer;
  }

  .bar-button:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .send {
    position: relative;
    flex: none;
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border: 0;
    border-radius: var(--radius-chip);
    background: var(--accent);
    color: var(--accent-text);
    cursor: pointer;
    transition:
      background var(--transition-fast),
      transform var(--motion-duration-fast) var(--motion-ease-standard);
  }

  .send:not(:disabled):hover {
    background: var(--accent-hover);
  }

  .send:not(:disabled):active {
    transform: scale(0.94);
  }

  .send.stopping {
    background: var(--text-primary);
    color: var(--bg-primary);
  }

  .send.stopping:hover {
    background: var(--text-primary);
    opacity: 0.85;
  }

  .send:disabled {
    opacity: var(--disabled-opacity);
    cursor: default;
  }

  .glyph {
    grid-area: 1 / 1;
    display: grid;
    place-items: center;
    transition:
      opacity var(--motion-duration-fast) ease,
      transform var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .stop-glyph span {
    width: 8px;
    height: 8px;
    border-radius: var(--radius-2xs);
    background: currentColor;
  }

  .stop-glyph,
  .send.stopping .send-glyph {
    opacity: 0;
    transform: scale(0.6);
  }

  .send.stopping .stop-glyph {
    opacity: 1;
    transform: none;
  }

  button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
