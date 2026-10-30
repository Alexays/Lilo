<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { untrack } from "svelte";
  import { cubicIn } from "svelte/easing";
  import { fade } from "svelte/transition";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { dismissable } from "../../lib/actions/dismissable";
  import { conversationActions } from "./conversationActions";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    clearChosenProject,
    closeAskBar,
    getAgents,
    getAskSelection,
    getChosenProject,
    getProjects,
    projectName,
    isAskBarOpen,
  } from "../../stores/conversations.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import AgentTile from "./AgentTile.svelte";
  import MenuPicker from "./MenuPicker.svelte";
  import PromptField, { type AttachmentDraft } from "./PromptField.svelte";

  const CHOOSE = "lilo:choose-folder";

  const open = $derived(isAskBarOpen());
  let text = $state("");
  let attachments = $state.raw<AttachmentDraft[]>([]);
  let agentId = $state("");
  let project = $state("");
  let ownCopy = $state(false);
  let pageTabId = $state<string | null>(null);
  let field: ReturnType<typeof PromptField> | undefined = $state();
  let refreshed = false;
  let catalogAtOpen: unknown = null;

  // Each opening starts from what is on screen: the page and its selection, the last agent and project.
  $effect(() => {
    if (!open) return;
    untrack(() => {
      const page = getActiveTab();
      const web = page?.kind === "web" && page.url ? page : null;
      pageTabId = web?.id ?? null;
      text = "";
      const selection = web ? getAskSelection() : "";
      attachments = web
        ? [
            { key: `tab:${web.id}`, label: t("agents.ask.thisPage"), attachment: { kind: "tab", tabId: web.id } },
            ...(selection
              ? [{
                  key: `selection:${web.id}`,
                  label: `"${selection.length > 32 ? `${selection.slice(0, 32).trimEnd()}...` : selection}"`,
                  attachment: { kind: "selection" as const, tabId: web.id },
                }]
              : []),
          ]
        : [];
      ownCopy = false;
      refreshed = false;
      catalogAtOpen = getAgents();
      conversationActions.loadCatalog(false);
    });
    requestAnimationFrame(() => field?.focus());
  });

  // An empty catalog after the cached load means nothing was cached yet: fetch the registry.
  $effect(() => {
    const agents = getAgents();
    if (!open || refreshed || agents === catalogAtOpen || agents.length > 0) return;
    refreshed = true;
    conversationActions.loadCatalog(true);
  });

  $effect(() => {
    const agents = getAgents();
    if (agents.length === 0 || agents.some((agent) => agent.id === agentId)) return;
    const last = getSetting("agentsLastAgent", "");
    agentId = agents.some((agent) => agent.id === last) ? last : agents[0].id;
  });

  $effect(() => {
    const chosen = getChosenProject();
    if (chosen) {
      project = chosen;
      setSetting("agentsLastProject", chosen);
      clearChosenProject();
      return;
    }
    if (project) return;
    project = getSetting("agentsLastProject", "") || getProjects()[0] || "";
  });

  const projectOptions = $derived.by(() => {
    const paths = getProjects().includes(project) || !project ? getProjects() : [project, ...getProjects()];
    return [
      ...paths.map((path) => ({ value: path, label: projectName(path), detail: path, icon: "folder" as const })),
      { value: CHOOSE, label: t("agents.ask.chooseFolder"), icon: "folder" as const },
    ];
  });
  const agent = $derived(getAgents().find((candidate) => candidate.id === agentId));
  const canStart = $derived(!!agentId && !!project && text.trim().length > 0);

  function start(background: boolean): void {
    if (!canStart) return;
    conversationActions.start({
      agentId,
      cwd: project,
      text: text.trim(),
      attachments: attachments.map((draft) => draft.attachment),
      background,
      ownCopy,
    });
    setSetting("agentsLastAgent", agentId);
    setSetting("agentsLastProject", project);
    closeAskBar();
  }

  // Closes quicker than it opens, sinking back the way it rose; the bar is centred by its transform.
  function closeBar(_node: Element) {
    return {
      duration: prefersReducedMotion() ? 0 : 140,
      easing: cubicIn,
      css: (t: number, u: number) => `opacity:${t};transform:translate(-50%,${u * 6}px) scale(${1 - u * 0.02})`,
    };
  }

  function pickProject(value: string): void {
    if (value === CHOOSE) conversationActions.chooseProject();
    else project = value;
  }
</script>

{#if open}
  <div class="ask-root chrome-content-overlay-root">
    <!-- Veils the page and any conversation composer under the bar: one field in front, never two. -->
    <div class="ask-scrim" transition:fade={{ duration: prefersReducedMotion() ? 0 : 160 }}></div>
    <div
      class="ask-bar float-surface"
      out:closeBar
      role="dialog"
      aria-label={t("agents.ask.label")}
      use:reportInteractiveZone={{ id: "agents-ask-bar" }}
      {@attach dismissable({ onDismiss: closeAskBar, escape: true })}
    >
      <PromptField
        bind:this={field}
        bind:text
        bind:attachments
        placeholder={t("agents.ask.placeholder")}
        ariaLabel={t("agents.ask.label")}
        {pageTabId}
        cwd={project}
        onsubmit={start}
      />
      <div class="ask-controls">
        <MenuPicker
          value={agentId}
          options={getAgents().map((candidate) => ({ value: candidate.id, label: candidate.name, detail: candidate.description || undefined, agentId: candidate.id }))}
          ariaLabel={t("agents.ask.agent")}
          onchange={(value) => (agentId = value)}
        >
          {#if agent}<AgentTile agentId={agent.id} />{/if}
          <span class="picker-label">{agent?.name ?? t("agents.ask.loadingAgents")}</span>
        </MenuPicker>
        <MenuPicker value={project || CHOOSE} options={projectOptions} ariaLabel={t("agents.ask.project")} onchange={pickProject}>
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
            <path d="M2 4.5h4l1.5 1.5H14v6.5H2z" />
          </svg>
          <span class="picker-label">{project ? projectName(project) : t("agents.ask.chooseProject")}</span>
        </MenuPicker>
        <button
          type="button"
          class="own-copy"
          aria-pressed={ownCopy}
          title={t("agents.ask.ownCopyHint")}
          onclick={() => (ownCopy = !ownCopy)}
        >
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
            <circle cx="4" cy="3.5" r="1.8" /><circle cx="4" cy="12.5" r="1.8" /><circle cx="12" cy="6" r="1.8" />
            <path d="M4 5.3v5.4M12 7.8c0 2.5-3 2.2-6.5 3.6" />
          </svg>
          {t("agents.ask.ownCopy")}
        </button>
        <span class="spacer"></span>
        <button
          type="button"
          class="send"
          disabled={!canStart}
          aria-label={t("agents.ask.start")}
          title={`⏎ ${t("agents.ask.openBeside")}, ⌘⏎ ${t("agents.ask.openBackground")}`}
          onclick={() => start(false)}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
            <path d="M6 10V2M2.5 5.5L6 2l3.5 3.5" stroke="currentColor" fill="none" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .ask-root {
    pointer-events: none;
    z-index: 1000;
  }

  .ask-scrim {
    position: absolute;
    inset: 0;
    border-radius: var(--chrome-overlay-boundary-radius);
    background: var(--chrome-overlay-backdrop-tint);
    backdrop-filter: blur(var(--chrome-overlay-backdrop-blur));
  }

  .ask-bar {
    position: absolute;
    left: 50%;
    bottom: var(--space-24);
    transform: translateX(-50%);
    width: min(620px, calc(100% - var(--space-32)));
    box-sizing: border-box;
    padding: var(--space-12) var(--space-12) var(--space-10) var(--space-16);
    border-radius: var(--radius-xl);
    pointer-events: auto;
    transform-origin: 50% 100%;
    animation: rise var(--motion-duration-slow) var(--motion-ease-bounce) both;
  }

  @keyframes rise {
    from {
      opacity: 0;
      transform: translate(-50%, 10px) scale(0.98);
    }
  }

  .ask-controls {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    margin-top: var(--space-10);
    min-width: 0;
  }

  .ask-controls :global(.menu-picker) {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .picker-label {
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .own-copy {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: var(--control-height-sm);
    padding: 0 var(--space-8);
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    white-space: nowrap;
    cursor: pointer;
  }

  .own-copy:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .own-copy[aria-pressed="true"] {
    background: color-mix(in srgb, var(--success) 16%, transparent);
    color: var(--success-text);
  }

  .spacer {
    flex: 1;
  }

  .hint {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    white-space: nowrap;
    overflow: hidden;
  }

  kbd {
    margin-left: var(--space-6);
    font-family: inherit;
    color: var(--text-secondary);
  }

  .send {
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
  }

  .send:not(:disabled):hover {
    background: var(--accent-hover);
  }

  .send:disabled {
    opacity: var(--disabled-opacity);
    cursor: default;
  }

  button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
