<script lang="ts" module>
  import type { IconName } from "../ui/icons";
  import type { AttachmentDraft } from "./PromptField.svelte";

  const SUGGESTIONS: { key: string; icon: IconName }[] = [
    { key: "explain", icon: "book" },
    { key: "fixBug", icon: "bug" },
    { key: "tests", icon: "flask" },
  ];

  /** What was typed and not sent, by conversation: the view goes when its tab is not shown. */
  const drafts: Record<string, { text: string; attachments: AttachmentDraft[] }> = {};
  /** When each conversation was first seen working: the timer's start while its thread is not loaded yet, kept across views. */
  const workingSince: Record<string, number> = {};
</script>

<script lang="ts">
  import { modeIcon, modelLogo, supersededModels } from "./modelLogos";
  import "../../lib/i18n/agentsCatalog";
  import { onDestroy, untrack } from "svelte";
  import { cubicOut } from "svelte/easing";
  import { fade } from "svelte/transition";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { conversationActions } from "./conversationActions";
  import { announce } from "../../lib/announce";
  import type { BridgeSplitPaneFrame } from "../../lib/bridge/protocol";
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
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
  import type { ImageRef, PermissionItem, QuestionItem, ThreadItem, ToolCallItem, UserMessageItem } from "./conversationModel";
  import Icon from "../ui/Icon.svelte";
  import Lightbox from "./Lightbox.svelte";
  import MenuPicker from "./MenuPicker.svelte";
  import PermissionButtons from "./PermissionButtons.svelte";
  import PlanTray from "./PlanTray.svelte";
  import PromptField from "./PromptField.svelte";
  import QuestionForm from "./QuestionForm.svelte";
  import SignInCard from "./SignInCard.svelte";
  import ThreadRow, { type TurnSummary } from "./ThreadRow.svelte";
  import { formatDuration, itemSignature } from "./threadView";
  import WorkBlock, { describe } from "./WorkBlock.svelte";
  import { threadRoots } from "./threadFind";

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

  // A file the agent read or changed in this thread, by the name a message gives it: `faq.html` opens, `console.log` does not.
  /** An option the agent names by id (`plugin:code-simplifier`, `xhigh`) as words a menu can show. */
  function optionLabel(name: string): string {
    if (/\s/.test(name)) return name;
    const words = (name.split(":").pop() ?? name).replace(/[-_]+/g, " ").replace(/^x(?=high|low)/i, "extra ");
    return words.charAt(0).toUpperCase() + words.slice(1);
  }

  function knownFile(name: string): string | null {
    const bare = name.replace(/:\d+(?::\d+)?$/, "");
    if (!conversation || !/^[\w.@/~-]+\.[A-Za-z]\w*$/.test(bare)) return null;
    for (const call of conversation.thread.toolCalls.values()) {
      for (const path of [...call.diffs.map((diff) => diff.path), ...call.locations.map((location) => location.path)]) {
        if (path === bare || path.endsWith(`/${bare}`)) return path;
      }
    }
    return null;
  }
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
  // The agent lists its `/` commands once its session opens: asked once per view.
  let commandsRequested = false;
  let text = $state(untrack(() => drafts[tabId]?.text ?? ""));
  let attachments = $state.raw<AttachmentDraft[]>(untrack(() => drafts[tabId]?.attachments ?? []));
  onDestroy(() => {
    if (text.trim() || attachments.length) drafts[tabId] = { text, attachments };
    else delete drafts[tabId];
  });
  let threadEl: HTMLDivElement | undefined = $state();
  $effect(() => {
    if (!threadEl) return;
    const id = tabId;
    threadRoots.set(id, threadEl);
    return () => {
      if (threadRoots.get(id) === threadEl) threadRoots.delete(id);
    };
  });
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

  /** following: the end stays in view as the thread grows. free: the reader scrolled up. */
  let scrollMode = $state<"following" | "free">("following");
  let atBottom = $state(true);
  // A prompt sent from here glides into view; growth after it follows at once.
  let glidePending = false;
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
    // Prompts waiting for the running turn close the thread, whatever that turn adds after them.
    const waiting: UserMessageItem[] = [];
    let turn: Turn | null = null;
    let work: WorkRow | null = null;
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- local to one run, only its size is kept
    let files = new Set<string>();
    let added = 0;
    let removed = 0;
    let finalText = "";
    for (let i = start; i < items.length; i++) {
      const item = items[i];
      if (item.kind === "user" && item.queued) {
        waiting.push(item);
        continue;
      }
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
        for (const call of [item, ...item.children]) {
          for (const diff of call.diffs) {
            files.add(diff.path);
            added += diff.added;
            removed += diff.removed;
          }
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
    for (const item of waiting) {
      prompt++;
      out.push({
        key: `t${item.id}`,
        rows: [{ kind: "item", key: `i${item.id}`, item, sig: itemSignature(item, undone), promptIndex: prompt, canRestore: false, turn: null }],
      });
    }
    return out;
  });
  // The call running now, in the words its row uses: the working line says what the agent is on.
  const step = $derived.by(() => {
    void version;
    if (!working || !conversation) return null;
    const { items } = conversation.thread;
    for (let i = items.length - 1; i >= 0 && items[i].kind === "toolCall"; i--) {
      const call = items[i];
      if (call.kind !== "toolCall" || (call.status !== "pending" && call.status !== "in_progress")) continue;
      const view = describe(call, header.cwd);
      if (view.command) return `$ ${view.target}`;
      if (view.verb) return `${t(view.verb)} ${view.path ? view.target.slice(view.target.lastIndexOf("/") + 1) : view.target}`;
      return view.target || null;
    }
    return null;
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
      title: tabDisplayTitle(tab?.title ?? "") || thread?.title || getConversationSummary(tabId)?.title,
      agentId,
      agentName: getAgent(agentId)?.name || agentId,
      project: cwd.split("/").filter(Boolean).pop() ?? "",
      cwd,
      ownCopy: cwd.includes("/Worktrees/"),
      branch: tab?.gitBranch ?? "",
      modes,
      extraConfigs,
      // Read beside the model, as Claude Code shows it: the effort the next turn runs at, unless it is the agent's default.
      effort: (() => {
        const config = extraConfigs.find((option) => option.category === "thought_level");
        if (!config || /^default$/i.test(config.currentValue)) return null;
        const name = config.options.find((option) => option.value === config.currentValue)?.name;
        return name ? optionLabel(name) : null;
      })(),
      modeId: thread?.modeId ?? "",
      configs,
      usage: thread?.usage && thread.usage.size > 0 ? thread.usage : null,
      queued: conversation?.queued ?? 0,
      error: conversation?.error ?? null,
      authMethods: conversation?.authMethods ?? [],
      signingIn: conversation?.signingIn ?? null,
      commands: thread?.commands ?? [],
    };
  });
  const usagePercent = $derived(header.usage ? Math.min(100, Math.round((header.usage.used / header.usage.size) * 100)) : 0);
  // Below half the context, compacting saves little and Claude refuses a short thread.
  const canCompact = $derived(!working && usagePercent >= 50 && header.commands.some((command) => command.name === "compact"));
  // The thread replaces this array only on a rate limit event, so the formatting below runs that rarely.
  const planLimits = $derived.by(() => {
    void version;
    return conversation?.thread.planLimits;
  });
  const plan = $derived.by(() => {
    const now = Date.now();
    // A window whose reset has passed no longer says anything about the plan.
    const live = planLimits?.filter((limit) => limit.resetsAt > now) ?? [];
    if (live.length === 0) return null;
    const time = new Intl.DateTimeFormat(getFormatLocale(), { hour: "numeric", minute: "2-digit" });
    const dayAndTime = new Intl.DateTimeFormat(getFormatLocale(), { weekday: "short", hour: "numeric", minute: "2-digit" });
    return {
      percent: Math.max(...live.map((limit) => limit.percent)),
      lines: live.map((limit) =>
        t(limit.window === "five_hour" ? "agents.conversation.planSession" : "agents.conversation.planWeek", {
          percent: limit.percent,
          time: (limit.resetsAt - now < 86_400_000 ? time : dayAndTime).format(limit.resetsAt),
        }),
      ),
    };
  });
  // The agent's task list docks over the composer while it matters, and goes back to the thread once all is done.
  const todo = $derived.by(() => {
    void version;
    const entries = conversation?.thread.plan?.entries;
    return entries?.length ? [...entries] : null;
  });
  const todoPinned = $derived(todo !== null && (working || todo.some((entry) => entry.status !== "completed")));
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
    if (scrollMode !== "following") return;
    const max = el.scrollHeight - el.clientHeight;
    if (!glidePending) return scrollTo(el, max);
    glidePending = false;
    glideTo(el, max);
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

  // A row that folds, or a taller pane, can bring the end into view without any scroll event.
  $effect(() => {
    const thread = threadEl;
    const column = columnEl;
    if (!thread || !column) return;
    const observer = new ResizeObserver(() => {
      if (scrollMode !== "free" || thread.scrollHeight - thread.scrollTop - thread.clientHeight >= PIN_SLACK) return;
      atBottom = true;
      scrollMode = "following";
    });
    observer.observe(thread);
    observer.observe(column);
    return () => observer.disconnect();
  });

  function jumpToLatest(): void {
    if (!threadEl) return;
    scrollMode = "following";
    glideTo(threadEl, threadEl.scrollHeight - threadEl.clientHeight);
  }

  // One timer, only while a turn runs: it writes the text in place instead of re-rendering.
  $effect(() => {
    const el = elapsedEl;
    if (!working) delete workingSince[tabId];
    if (!working || !el) return;
    const since = (workingSince[tabId] ??= Date.now());
    const tick = () => {
      el.textContent = formatDuration(Date.now() - (getOpenConversation(tabId)?.thread.turnStartedAt ?? since));
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

  const pending = $derived.by(() => {
    void version;
    return pendingPermission();
  });
  // A form the agent asks to fill: Claude's multiple-choice questions come this way.
  const pendingQuestion = $derived.by((): QuestionItem | null => {
    void version;
    const items = conversation?.thread.items ?? [];
    for (let i = items.length - 1; i >= 0; i--) {
      const item = items[i];
      if (item.kind === "question" && item.answer === null) return item;
    }
    return null;
  });
  const asking = $derived(pending !== null || pendingQuestion !== null);
  // VoiceOver hears what the eye sees change: a turn ending, a question waiting. An error is its own alert.
  let wasBusy = false;
  $effect(() => {
    if (wasBusy && !busy && !asking && !header.error) announce(t("agents.badge.done"));
    wasBusy = busy;
  });
  let announcedRequest: string | number | null = null;
  $effect(() => {
    const request = pending?.requestId ?? pendingQuestion?.requestId ?? null;
    if (request !== null && request !== announcedRequest && live)
      announce(pending ? `${t("agents.conversation.permissionTitle")} ${pendingCommand}` : pendingQuestion?.message ?? "");
    announcedRequest = request;
  });
  // What the agent asks to run, as it will run: the command for a shell call, else its title.
  const pendingCommand = $derived.by(() => {
    const call = pending?.toolCall;
    if (!call) return "";
    const command = (call.rawInput !== null && typeof call.rawInput === "object" ? (call.rawInput as Record<string, unknown>).command : undefined);
    if (typeof command === "string") return command;
    // Codex sends argv, usually ["bash", "-lc", script].
    if (Array.isArray(command)) return command.length === 3 && command[1] === "-lc" ? String(command[2]) : command.join(" ");
    return call.title ?? "";
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
    // Cmd Return from an empty field stops the running turn, so the queued prompt goes now.
    if (!prompt && attachments.length === 0) {
      if (interrupt && header.queued > 0) stop();
      return;
    }
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
    if (addLocalPrompt(tabId, prompt, sent.map((draft) => ({ label: draft.label, uri: "" }))) === null) return;
    glidePending = true;
    scrollMode = "following";
  }

  function compact(): void {
    conversationActions.send({ tabId, text: "/compact", attachments: [], interrupt: false });
    sentPending = true;
    addLocalPrompt(tabId, "/compact", []);
    scrollMode = "following";
  }

  function stop(): boolean {
    if (!working) return false;
    conversationActions.cancel(tabId);
    return true;
  }

  let questionForm = $state<QuestionForm>();

  function answerPending(allow: boolean, always = false): boolean {
    const permission = pendingPermission();
    if (!permission) return false;
    const option = always
      ? permission.options.find((candidate) => candidate.kind === "allow_always")
      : allow
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
        <span class="meta" use:tooltip={header.cwd}>
          <Icon name="folder" size={12} />
          <span class="meta-text">{header.project}</span>
        </span>
      {/if}
      {#if header.branch}
        <span class="meta" use:tooltip={t("agents.conversation.branch", { branch: header.branch })}>
          <Icon name="branch" size={12} />
          <span class="meta-text">{header.branch}</span>
        </span>
      {/if}
      {#if tab?.diffAdded || tab?.diffRemoved}
        <!-- Git's view of the project, so edits made through the shell count too. -->
        <button
          type="button"
          class="meta changes"
          aria-label={t("tabItem.showChanges", { added: tab.diffAdded ?? 0, removed: tab.diffRemoved ?? 0 })}
          use:tooltip={t("agents.turn.review")}
          onclick={() => conversationActions.openChanges(tabId)}
        >
          <Icon name="fileDiff" size={12} />
          {#if tab.diffAdded}<span class="count-added">+{tab.diffAdded}</span>{/if}
          {#if tab.diffRemoved}<span class="count-removed">-{tab.diffRemoved}</span>{/if}
        </button>
      {/if}
      {#if header.ownCopy}
        <span class="meta" use:tooltip={t("agents.conversation.ownCopyHint")}>
          <Icon name="copy" size={12} />
          <span class="meta-text">{t("agents.conversation.ownCopy")}</span>
        </span>
      {/if}
      <span class="spacer"></span>
      {#if plan}
        <span
          class="gauge"
          in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}
          role="img"
          aria-label={plan.lines.join(", ")}
          use:tooltip={{ text: plan.lines[0], subtitle: plan.lines[1] }}
        >
          <span class="meter" class:high={plan.percent >= 90} style:--plan-used="{plan.percent}%"></span>
          {plan.percent}%
        </span>
      {/if}
      {#if header.usage && canCompact}
        <!-- The agent summarizes the thread to free its context, as Claude Code's /compact. -->
        <button
          type="button"
          class="gauge compact"
          in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}
          aria-label={`${t("agents.conversation.context", { percent: usagePercent })}, ${t("agents.conversation.compact")}`}
          use:tooltip={{ text: t("agents.conversation.context", { percent: usagePercent }), subtitle: t("agents.conversation.compactHint") }}
          onclick={compact}
        >
          <span class="ring" class:high={usagePercent >= 80} style:--context-used="{usagePercent}%"></span>
          {usagePercent}%
        </button>
      {:else if header.usage}
        <span
          class="gauge"
          in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}
          role="img"
          aria-label={t("agents.conversation.context", { percent: usagePercent })}
          use:tooltip={t("agents.conversation.context", { percent: usagePercent })}
        >
          <span class="ring" class:high={usagePercent >= 80} style:--context-used="{usagePercent}%"></span>
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
        <!-- Queued prompts close the thread: each starts a turn of its own that has not run yet. -->
        {#each turns as turn, turnIndex (turn.key)}
          {@const queued = turnIndex >= turns.length - header.queued}
          <div class="turn" class:queued>
            {#each turn.rows as row (row.key)}
              {@const permission = row.kind === "item" && (row.item.kind === "permission" || row.item.kind === "question")}
              {#if !(todoPinned && row.kind === "item" && row.item.kind === "plan")}
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
                    {knownFile}
                    onedit={(value) => {
                      text = value;
                      field?.focus();
                    }}
                  />
                {/if}
              </div>
              {/if}
            {/each}
            {#if queued}
              <div class="queued-tag" in:fade={{ duration: prefersReducedMotion() ? 0 : 120 }}>
                <Icon name="queue" size={11} />
                {t("agents.conversation.queuedTag")}
                <!-- The next one in line goes now: the running turn stops, as Cmd Return does from an empty field. -->
                {#if turnIndex === turns.length - header.queued}
                  <button type="button" class="send-now" use:tooltip={"\u2318 Return"} onclick={stop}>{t("agents.conversation.sendNow")}</button>
                {/if}
              </div>
            {/if}
            <!-- Where the reply appears, right under the prompt: what the agent is doing reads where the eye is. -->
            {#if working && turnIndex === turns.length - 1 - header.queued && header.signingIn?.screen}
              <SignInCard {tabId} agentId={header.agentId} agentName={header.agentName} screen={header.signingIn.screen} />
            {:else if working && turnIndex === turns.length - 1 - header.queued}
              <div class="activity" role="status" in:fade={{ duration: prefersReducedMotion() ? 0 : 120 }}>
                {#if asking}
                  <span class="pip" aria-hidden="true"></span>
                  <span class="status-label">{t("agents.status.waiting")}</span>
                {:else if header.signingIn}
                  <span class="dots" aria-hidden="true"><span></span><span></span><span></span></span>
                  <span class="status-label">{t("agents.status.signingIn", { agent: header.agentName })}</span>
                  <span class="status-hint">{t(header.signingIn.terminal ? "agents.status.signingInTerminalHint" : "agents.status.signingInHint")}</span>
                {:else}
                  <span class="dots" aria-hidden="true"><span></span><span></span><span></span></span>
                  {#if step}
                    {#key step}
                      <span class="status-label step" aria-hidden="true" in:fade={{ duration: prefersReducedMotion() ? 0 : 120 }}>{step}</span>
                    {/key}
                    <span class="visually-hidden">{t("agents.status.working")}</span>
                  {:else}
                    <span class="status-label">{t("agents.status.working")}</span>
                  {/if}
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
      {#if todoPinned && todo}
        <PlanTray entries={todo} />
      {/if}
      {#if pending}
        <!-- The question docks where the eye is, over the composer; Return and Esc answer it from an empty field. -->
        <div
          class="question float-surface"
          role="group"
          aria-label={t("agents.conversation.permissionTitle")}
          in:restingFly={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs + 120, easing: springEase, x: 0, y: 10 }}
        >
          <div class="question-head">
            <span class="question-icon">
              <AgentTile agentId={header.agentId} />
              <span class="question-dot" aria-hidden="true"></span>
            </span>
            <span class="question-title">{t("agents.conversation.permissionTitle")}</span>
            <span class="question-state">{t("agents.status.waiting")}</span>
          </div>
          {#if pendingCommand}
            <div class="question-command">{#if pending.toolCall.kind === "execute"}<span class="prompt-sign" aria-hidden="true">$</span>{/if}{pendingCommand}</div>
          {/if}
          <div class="question-foot">
            {#if header.cwd}<span class="question-path" use:tooltip={header.cwd}>{header.cwd.replace(/^\/Users\/[^/]+/, "~")}</span>{/if}
            <PermissionButtons {tabId} requestId={String(pending.requestId)} options={pending.options} keys />
          </div>
        </div>
      {:else if pendingQuestion}
        {#key pendingQuestion.requestId}
          <QuestionForm bind:this={questionForm} {tabId} item={pendingQuestion} agentId={header.agentId} />
        {/key}
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
          oncommandsneeded={() => {
            if (commandsRequested) return;
            commandsRequested = true;
            conversationActions.loadCommands(tabId);
          }}
          onsubmit={send}
          onemptyreturn={(always) => attachments.length === 0 && (answerPending(true, always) || (questionForm?.answer("accept") ?? false))}
          onescape={() => answerPending(false) || (questionForm?.answer("decline") ?? false) || stop()}
          onemptykey={(key) => questionForm?.pick(key) ?? false}
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
            {@const older = config.category === "model" ? supersededModels(config.options.map((option) => option.name)) : null}
            <MenuPicker
              value={config.currentValue}
              options={config.options
                .map((option) => {
                  const superseded = older?.has(option.name);
                  // An older model's blurb repeats its newer sibling's, so its row is the name alone.
                  return {
                    value: option.value,
                    label: option.name,
                    detail: superseded ? undefined : (option.description ?? undefined),
                    icon: config.category === "mode" ? modeIcon(`${option.value} ${option.name}`) : ("sparkle" as const),
                    logo: config.category === "model" ? modelLogo(`${option.value} ${option.name}`) : undefined,
                    group: superseded ? t("agents.conversation.olderModels") : undefined,
                  };
                })
                .sort((a, b) => Number(!!a.group) - Number(!!b.group))}
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
                label: optionLabel(option.name),
                group: config.name,
                checked: option.value === config.currentValue,
              })))}
              ariaLabel={t("agents.conversation.moreOptions")}
              onchange={(value) => {
                const [configId, optionValue] = value.split("\n");
                conversationActions.setConfig(tabId, configId, optionValue);
              }}
            >
              <Icon name={header.effort ? "brain" : "sliders"} size={14} />
              {#if header.effort}<span class="picker-label effort">{header.effort}</span>{/if}
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

  @media (prefers-color-scheme: dark) {
    .conversation {
      --bg-primary: var(--conversation-bg);
      --float-surface: var(--conversation-surface);
    }
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

  .meta {
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    max-width: 180px;
    margin-left: var(--space-4);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    white-space: nowrap;
  }

  .changes {
    height: 22px;
    /* The padding is the hover background's: the content lines up with the other metadata. */
    margin-left: calc(var(--space-4) - var(--space-6));
    padding: 0 var(--space-6);
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    font: inherit;
    font-variant-numeric: tabular-nums;
    cursor: pointer;
  }

  .changes:hover {
    background: var(--bg-hover);
  }

  .changes:focus-visible {
    outline: var(--focus-outline);
  }

  /* The sidebar's diff colours, pulled toward the text so both read on any Space tint. */
  .count-added {
    color: color-mix(in srgb, var(--diff-added) 70%, var(--text-primary));
  }

  .count-removed {
    color: color-mix(in srgb, var(--diff-removed) 70%, var(--text-primary));
  }

  .meta-text {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .question {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    width: 100%;
    box-sizing: border-box;
    margin-bottom: var(--space-8);
    padding: var(--space-12) var(--space-12) var(--space-12) var(--space-16);
    border-radius: var(--radius-lg);
  }

  .question-head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-width: 0;
  }

  .question-icon {
    position: relative;
    flex: none;
    display: grid;
  }

  .question-dot {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--float-surface);
  }

  .question-title {
    flex: 1;
    min-width: 0;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .question-state {
    flex: none;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .question-command {
    max-height: 120px;
    overflow: auto;
    padding: var(--space-8) var(--space-12);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
    font: var(--font-size-sm) / 1.5 ui-monospace, "SF Mono", Menlo, monospace;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    user-select: text;
  }

  .prompt-sign {
    margin-right: var(--space-8);
    color: var(--text-muted);
  }

  .question-foot {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    min-width: 0;
  }

  .question-path {
    flex: 1;
    min-width: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .question-foot :global(.permission-buttons) {
    margin-left: auto;
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

  .ring.high {
    background: conic-gradient(var(--warning) 0 var(--context-used), var(--text-primary-tint-12) var(--context-used) 100%);
  }

  .gauge.compact {
    height: 22px;
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .gauge.compact:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .gauge.compact:focus-visible {
    outline: var(--focus-outline);
  }

  @property --plan-used {
    syntax: "<percentage>";
    inherits: false;
    initial-value: 0%;
  }

  /* A level, not a ring: read apart from the context gauge beside it. */
  .meter {
    width: 6px;
    height: 13px;
    border-radius: var(--radius-chip);
    background: linear-gradient(to top, var(--accent) 0 var(--plan-used), var(--text-primary-tint-12) var(--plan-used) 100%);
    transition: --plan-used var(--motion-duration-slow) var(--motion-ease-organic);
  }

  .meter.high {
    background: linear-gradient(to top, var(--warning) 0 var(--plan-used), var(--text-primary-tint-12) var(--plan-used) 100%);
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

  /* Not sent yet: the prompt waits, dimmed, under the turn still running. */
  .turn.queued .row {
    opacity: 0.6;
  }

  .queued-tag {
    display: inline-flex;
    align-items: center;
    align-self: flex-end;
    gap: var(--space-4);
    margin-top: calc(-1 * var(--space-6));
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .send-now {
    margin-left: var(--space-4);
    padding: 0 var(--space-4);
    border: none;
    border-radius: var(--radius-xs);
    background: transparent;
    color: var(--accent-ink);
    font: inherit;
    cursor: pointer;
  }

  .send-now:hover {
    background: var(--bg-hover);
  }

  .send-now:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  /* A pending question docks over the composer and leaves its row empty. */
  .row:empty {
    display: none;
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

  /* The thread fades out above the composer and stays hidden in the gap below it. */
  .dock::before {
    content: "";
    position: absolute;
    inset: calc(-1 * var(--space-32)) calc(-1 * var(--space-32)) calc(-1 * var(--space-16));
    z-index: -1;
    background: linear-gradient(transparent, var(--bg-primary) var(--space-32));
    pointer-events: none;
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

  .status-label {
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
  }

  /* A band of the page colour sweeps over the words: moved by transform alone, so it costs no repaint. */
  .step {
    position: relative;
    min-width: 0;
    max-width: 48ch;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .step::after {
    content: "";
    position: absolute;
    inset: 0;
    background: linear-gradient(90deg, transparent, color-mix(in srgb, var(--bg-primary) 65%, transparent), transparent);
    transform: translateX(-100%);
    animation: step-sweep 2.2s var(--motion-ease-standard) infinite;
  }

  @keyframes step-sweep {
    70%,
    100% {
      transform: translateX(100%);
    }
  }

  .visually-hidden {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
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

  .effort {
    color: var(--text-secondary);
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
