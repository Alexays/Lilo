<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { untrack } from "svelte";
  import { cubicIn } from "svelte/easing";
  import { fade } from "svelte/transition";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { dismissable } from "../../lib/actions/dismissable";
  import { conversationActions } from "./conversationActions";
  import { t } from "../../lib/i18n/state.svelte";
  import { formatShortcut } from "../../lib/inputParser";
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
  import { tooltip } from "../../lib/tooltip";
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
  let pageTabId = $state<string | null>(null);
  let field: ReturnType<typeof PromptField> | undefined = $state();
  let refreshed = false;
  let catalogAtOpen: unknown = null;
  let catalogLoaded = $state(false);

  // Each opening starts from what is on screen: the page and its selection, the last agent and project.
  $effect(() => {
    if (!open) return;
    untrack(() => {
      const page = getActiveTab();
      // A page that failed to load holds only Lilo's error screen: nothing worth the agent's context.
      const web = page?.kind === "web" && page.url && !page.hasNavigationError ? page : null;
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
      project = getSetting("agentsLastProject", "");
      refreshed = false;
      catalogLoaded = false;
      catalogAtOpen = getAgents();
      conversationActions.loadCatalog(false);
    });
    requestAnimationFrame(() => field?.focus());
  });

  // An empty catalog after the cached load means nothing was cached yet: fetch the registry.
  $effect(() => {
    const agents = getAgents();
    if (!open || agents === catalogAtOpen) return;
    if (refreshed || agents.length > 0) {
      catalogLoaded = true;
      return;
    }
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
    if (!chosen) return;
    project = chosen;
    setSetting("agentsLastProject", chosen);
    clearChosenProject();
  });

  const projectOptions = $derived.by(() => {
    const paths = getProjects().includes(project) || !project ? getProjects() : [project, ...getProjects()];
    return [
      { value: "", label: t("agents.ask.noFolder"), detail: t("agents.ask.noFolderDetail"), icon: "folder" as const },
      ...paths.map((path) => ({ value: path, label: projectName(path), detail: path, icon: "folder" as const })),
      { value: CHOOSE, label: t("agents.ask.chooseFolder"), icon: "folder" as const },
    ];
  });
  const agent = $derived(getAgents().find((candidate) => candidate.id === agentId));
  const canStart = $derived(!!agentId && text.trim().length > 0);

  function start(background: boolean): void {
    if (!canStart) return;
    conversationActions.start({
      agentId,
      cwd: project,
      text: text.trim(),
      attachments: attachments.map((draft) => draft.attachment),
      background,
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
    <!-- Veils any conversation composer under the bar: one field in front, never two. A page being asked about stays readable. -->
    <div class="ask-scrim" class:page={pageTabId} transition:fade={{ duration: prefersReducedMotion() ? 0 : 160 }}></div>
    <div
      class="ask-bar float-surface"
      out:closeBar
      role="dialog"
      aria-label={t("agents.ask.label")}
      use:reportInteractiveZone={{ id: "agents-ask-bar" }}
      {@attach dismissable({ onDismiss: closeAskBar, ignore: "[role='menu']", escape: true })}
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
        <MenuPicker value={project} options={projectOptions} ariaLabel={t("agents.ask.project")} onchange={pickProject}>
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
            <path d="M2 4.5h4l1.5 1.5H14v6.5H2z" />
          </svg>
          <span class="picker-label" class:quiet={!project}>{project ? projectName(project) : t("agents.ask.noFolder")}</span>
        </MenuPicker>
        <span class="spacer"></span>
        <MenuPicker
          value={agentId}
          options={getAgents().map((candidate) => ({ value: candidate.id, label: candidate.name, detail: candidate.description || undefined, agentId: candidate.id }))}
          ariaLabel={t("agents.ask.agent")}
          onchange={(value) => (agentId = value)}
        >
          {#if agent}<AgentTile agentId={agent.id} />{/if}
          {#if agent}
            <span class="picker-label">{agent.name}</span>
          {:else if catalogLoaded}
            <span class="picker-label quiet">{t("agents.ask.noAgents")}</span>
          {:else}
            <span class="catalog-spinner" aria-hidden="true"></span>
          {/if}
        </MenuPicker>
        <button
          type="button"
          class="send"
          disabled={!canStart}
          aria-label={t("agents.ask.start")}
          aria-keyshortcuts="Enter Meta+Enter"
          use:tooltip={{ text: t("agents.ask.start"), subtitle: t("agents.ask.backgroundHint", { shortcut: formatShortcut("Cmd+Enter") }), shortcut: formatShortcut("Enter"), placement: "top" }}
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

  .ask-scrim.page {
    backdrop-filter: none;
  }

  .ask-bar {
    position: absolute;
    left: 50%;
    bottom: var(--space-24);
    transform: translateX(-50%);
    width: min(700px, calc(100% - var(--space-32)));
    box-sizing: border-box;
    padding: var(--space-10) var(--space-8) var(--space-8) var(--space-12);
    border-radius: var(--radius-lg);
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

  .picker-label.quiet {
    color: var(--text-secondary);
  }

  /* Shows only past 300 ms, and stops after about 30 s so a stalled catalog never keeps the display link up. */
  .catalog-spinner {
    width: 12px;
    height: 12px;
    box-sizing: border-box;
    border-radius: 50%;
    border: 1.5px solid var(--text-primary-tint-12);
    border-top-color: var(--text-secondary);
    animation:
      ask-catalog-appear 1ms 300ms both,
      ask-catalog-spin 0.9s linear 300ms 33 forwards;
  }

  @keyframes ask-catalog-appear {
    from {
      opacity: 0;
    }
  }

  @keyframes ask-catalog-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .catalog-spinner {
      animation: ask-catalog-appear 1ms 300ms both;
    }
  }


  .spacer {
    flex: 1;
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
