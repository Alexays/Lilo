<script lang="ts">
  import UiBadge from "../ui/UiBadge.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import UiShellFrame from "../ui/UiShellFrame.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import BottomConfirmSheet from "../ui/BottomConfirmSheet.svelte";
  import PanelHeader from "../ui/PanelHeader.svelte";
  import TabFolderItem from "../sidebar/TabFolderItem.svelte";
  import TabItem from "../sidebar/TabItem.svelte";
  import {
    getDesignSystemShellSection,
    isDesignSystemShellOpen,
  } from "../../stores/panels.svelte";
  import { getDesignSystemSection } from "./designSystemModel";
  import type { FolderState } from "../../stores/folders.svelte";
  import type { TabState } from "../../stores/tabs.svelte";

  const shellOpen = $derived(isDesignSystemShellOpen());
  const activeSection = $derived(getDesignSystemShellSection());
  const sectionMeta = $derived(getDesignSystemSection(activeSection));

  const colorTokens = [
    ["Primary", "var(--bg-primary)"],
    ["Sidebar", "var(--sidebar-bg)"],
    ["Hover", "var(--bg-hover)"],
    ["Active", "var(--bg-active)"],
    ["Accent", "var(--accent)"],
    ["Text", "var(--text-primary)"],
  ];

  const demoTabBase = {
    url: "https://lilo.browser/design-system",
    title: "Design System",
    isLoading: false,
    canGoBack: true,
    canGoForward: false,
    progress: 1,
    isPinned: false,
    isBookmarked: false,
    isClosed: false,
    isAudioPlaying: false,
    isMuted: false,
    isMicrophoneActive: false,
    isMicrophoneMuted: false,
    isCameraActive: false,
    isScreenSharing: false,
    spaceId: "design-system",
    hasNavigationError: false,
    navigationErrorCode: 0,
    navigationErrorDomain: "",
    navigationErrorDescription: "",
    navigationErrorURL: "",
  } satisfies Omit<TabState, "id">;

  const demoTabs: TabState[] = [
    {
      ...demoTabBase,
      id: "demo-active-tab",
      faviconDominantColor: "#7c8cff",
    },
    {
      ...demoTabBase,
      id: "demo-loading-tab",
      title: "Loading reference",
      url: "https://lilo.browser/loading",
      isLoading: true,
      progress: 0.42,
    },
    {
      ...demoTabBase,
      id: "demo-audio-tab",
      title: "Audio playing",
      url: "https://lilo.browser/audio",
      isAudioPlaying: true,
    },
    {
      ...demoTabBase,
      id: "demo-muted-tab",
      title: "Muted audio",
      url: "https://lilo.browser/muted",
      isMuted: true,
    },
    {
      ...demoTabBase,
      id: "demo-mic-tab",
      title: "Microphone active",
      url: "https://lilo.browser/microphone",
      isMicrophoneActive: true,
    },
  ];

  let demoFolderCollapsed = $state(false);

  const demoFolder = $derived({
    id: "demo-folder",
    spaceId: "design-system",
    name: "Research",
    color: "#7c8cff",
    isCollapsed: demoFolderCollapsed,
  } satisfies FolderState);

  const demoFolderChildTabs: TabState[] = [
    {
      ...demoTabBase,
      id: "demo-folder-docs-tab",
      title: "Design notes",
      url: "https://lilo.browser/design-notes",
      faviconDominantColor: "#5fd79a",
      groupId: "demo-folder",
    },
    {
      ...demoTabBase,
      id: "demo-folder-audit-tab",
      title: "Audit checklist",
      url: "https://lilo.browser/audit",
      faviconDominantColor: "#ffcc57",
      groupId: "demo-folder",
    },
  ];

</script>

<UiShellFrame
  active={shellOpen}
  ariaLabel="Design system"
  interactiveZoneId="design-system-shell"
  eyebrow="Design System"
  title={sectionMeta.title}
  description={sectionMeta.description}
>
    <div class="design-system-main">
        {#if activeSection === "foundations"}
          <section class="component-grid" aria-label="Foundation examples">
            <article class="component-card wide">
              <div class="component-card-header">
                <span>Color tokens</span>
                <UiBadge>Foundation</UiBadge>
              </div>
              <div class="token-grid">
                {#each colorTokens as token (token[0])}
                  <div class="token-card">
                    <span class="token-swatch" style:background={token[1]}></span>
                    <span class="token-name">{token[0]}</span>
                    <code>{token[1]}</code>
                  </div>
                {/each}
              </div>
            </article>
          </section>

          <UiInsetList title="Foundation Rules">
            <UiListRow title="Radius" description="Use 8px for controls, 12-14px for grouped surfaces." />
            <UiListRow title="Motion" description="Use 120-220ms transitions with var(--motion-ease-spring) for chrome movement." />
            <UiListRow title="Typography" description="Rows use 12-14px text; panel titles stay compact and centered." />
          </UiInsetList>
        {:else if activeSection === "layout"}
          <section class="component-grid" aria-label="Layout examples">
            <article class="component-card wide">
              <div class="component-card-header">
                <span>Overlay anatomy</span>
                <UiBadge>Layout</UiBadge>
              </div>
              <div class="layout-preview">
                <div class="layout-sidebar">Sidebar panel</div>
                <div class="layout-content">Content overlay</div>
              </div>
            </article>
          </section>

          <UiInsetList title="Layout Rules">
            <UiListRow title="Overlay pairing" description="A sidebar panel should have a matching content shell when the task needs detail." />
            <UiListRow title="Width" description="Content shells can use full content width; constrain inner examples only when readability requires it." />
            <UiListRow title="No backdrop" description="Chrome surfaces should feel native and avoid dimming the browser content unless modal." />
          </UiInsetList>
        {:else if activeSection === "sidebar"}
          <section class="component-grid" aria-label="Sidebar components">
            <article class="component-card">
              <div class="component-card-header">
                <span>Tab rows</span>
                <UiBadge>TabItem</UiBadge>
              </div>
              <div class="sidebar-demo">
                {#each demoTabs as tab, i (tab.id)}
                  <TabItem {tab} isActive={i === 0} interactive={false} disableTooltip />
                {/each}
              </div>
            </article>

            <article class="component-card">
              <div class="component-card-header">
                <span>Folder stack</span>
                <UiBadge>TabFolderItem</UiBadge>
              </div>
              <div class="sidebar-demo">
                <TabFolderItem
                  folder={demoFolder}
                  onCollapse={(collapsed) => {
                    demoFolderCollapsed = collapsed;
                  }}
                />
                {#if !demoFolderCollapsed}
                  <div class="folder-demo-children">
                    {#each demoFolderChildTabs as tab (tab.id)}
                      <TabItem {tab} isActive={false} interactive={false} disableTooltip />
                    {/each}
                  </div>
                {/if}
              </div>
            </article>
          </section>

          <UiInsetList title="Sidebar Rows">
            <UiListRow title="Active Tab" description="Active rows are highlighted by a traveling selection indicator (favicon-tinted glow); close slot stays reserved to avoid shifting." />
            <UiListRow title="Icon slot" description="Favicon, loader, or plus icon. Never start native image drags." />
            <UiListRow title="Action slot" description="Close, audio, and microphone controls reserve space so rows do not jump." />
            <UiListRow title="States" description="Active, hover, loading, closed, dragging, and ghost states are visually distinct." />
            <UiListRow title="Folder" description="Folder rows use the native folder icon and hover-only rename/delete actions." />
            <UiListRow title="New Tab" description="The empty tab row uses a plus icon and the same rhythm as normal rows." />
          </UiInsetList>
        {:else if activeSection === "panels"}
          <section class="component-grid" aria-label="Panel components">
            <article class="component-card wide">
              <div class="panel-demo">
                <PanelHeader title="Downloads" onclose={() => undefined} />
                <div class="panel-demo-body">
                  <div class="download-panel-preview">
                    <div class="download-panel-toolbar">
                      <UiSearchField value="report" ariaLabel="Search downloads" />
                      <UiButton variant="secondary">Clear</UiButton>
                    </div>

                    <div class="download-row active">
                      <div class="download-file-icon">PDF</div>
                      <div class="download-copy">
                        <strong>Quarterly report.pdf</strong>
                        <span>1.8 MB of 4.2 MB</span>
                        <div class="download-progress-track" aria-hidden="true">
                          <div class="download-progress-fill"></div>
                        </div>
                      </div>
                      <UiButton variant="secondary">Cancel</UiButton>
                    </div>

                    <div class="download-row">
                      <div class="download-file-icon muted">ZIP</div>
                      <div class="download-copy">
                        <strong>Extension build.zip</strong>
                        <span>Completed just now</span>
                      </div>
                      <UiButton>Reveal</UiButton>
                    </div>
                  </div>
                </div>
              </div>
            </article>

            <article class="component-card wide">
              <div class="component-card-header">
                <span>Confirmation sheet</span>
                <UiBadge>BottomConfirmSheet</UiBadge>
              </div>
              <div class="sheet-demo-stage">
                <BottomConfirmSheet
                  visible
                  title="Remove extension?"
                  message="This keeps the action close to the panel that triggered it."
                  confirmLabel="Remove"
                  cancelLabel="Cancel"
                  confirmAction={() => undefined}
                  cancelAction={() => undefined}
                />
              </div>
            </article>
          </section>

          <UiInsetList title="Panel Primitives">
            <UiListRow title="PanelHeader" description="52px bar with traffic-light spacer, actions and close control, then a full-width title row." />
            <UiListRow title="Toolbar" description="Panel search and clear actions sit above the working content, not inside row bodies." />
            <UiListRow title="Progress row" description="Long-running work shows file identity, short status, and a compact progress track." />
            <UiListRow title="Bottom sheet" description="Use for destructive confirmation that belongs to the current panel." />
          </UiInsetList>
        {:else if activeSection === "controls"}
          <section class="component-grid" aria-label="Control examples">
            <article class="component-card">
              <div class="component-card-header">
                <span>Buttons</span>
                <UiBadge>UiButton</UiBadge>
              </div>
              <div class="control-demo">
                <UiButton variant="primary">Primary</UiButton>
                <UiButton variant="secondary">Secondary</UiButton>
                <UiButton variant="danger">Danger</UiButton>
              </div>
            </article>

            <article class="component-card">
              <div class="component-card-header">
                <span>Signals</span>
                <UiBadge>UiBadge</UiBadge>
              </div>
              <div class="control-demo inline">
                <UiBadge tone="accent">Popup</UiBadge>
                <UiBadge>Content</UiBadge>
                <UiToggle checked ariaLabel="Demo toggle" />
              </div>
            </article>

          </section>

          <UiInsetList title="Controls">
            <UiListRow title="Button" description="Primary for commit, secondary for standard actions, danger for destructive actions.">
              {#snippet action()}
                <UiButton>Action</UiButton>
              {/snippet}
            </UiListRow>
            <UiListRow title="Toggle" description="Use for binary settings that apply immediately.">
              {#snippet action()}
                <UiToggle checked ariaLabel="Demo toggle" />
              {/snippet}
            </UiListRow>
            <UiListRow title="Badges" description="Use badges for metadata, not commands.">
              {#snippet action()}
                <span class="badge-row">
                  <UiBadge tone="accent">Popup</UiBadge>
                  <UiBadge>Content</UiBadge>
                </span>
              {/snippet}
            </UiListRow>
          </UiInsetList>
        {:else if activeSection === "patterns"}
          <section class="component-grid" aria-label="Pattern examples">
            <article class="component-card">
              <div class="component-card-header">
                <span>Extension action</span>
                <UiBadge>Recipe</UiBadge>
              </div>
              <div class="extension-pattern-card">
                <div class="extension-pattern-icon">A</div>
                <div class="extension-pattern-copy">
                  <strong>Ad Guard</strong>
                  <span>Blocks trackers and page overlays</span>
                  <div class="extension-pattern-badges">
                    <UiBadge tone="accent">Popup</UiBadge>
                    <UiBadge>Content</UiBadge>
                    <UiBadge>Background</UiBadge>
                  </div>
                </div>
                <UiToggle checked ariaLabel="Enable extension" />
              </div>
            </article>

            <article class="component-card">
              <div class="component-card-header">
                <span>Diagnostics block</span>
                <UiBadge>Recipe</UiBadge>
              </div>
              <div class="diagnostics-pattern">
                <div class="diagnostics-stat-grid">
                  <div>
                    <span>Startup</span>
                    <strong>412 ms</strong>
                  </div>
                  <div>
                    <span>Tabs</span>
                    <strong>18</strong>
                  </div>
                </div>
                <div class="diagnostics-log-row">
                  <span>Startup timeline</span>
                  <code>restore.finished</code>
                  <UiButton variant="secondary">Copy</UiButton>
                </div>
              </div>
            </article>
          </section>

          <UiInsetList title="Recipes">
            <UiListRow title="Extension row" description="Icon, identity, capability badges, and one immediate action on the right." />
            <UiListRow title="Diagnostics block" description="Small stats first, then logs with a compact copy action." />
            <UiListRow title="Settings list" description="Use UiInsetList when the user edits persistent preferences." />
          </UiInsetList>
        {/if}
    </div>
</UiShellFrame>

<style>
  .design-system-main {
    display: grid;
    gap: 16px;
    width: 100%;
  }

  .component-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 12px;
  }

  .component-card {
    display: grid;
    gap: 12px;
    min-width: 0;
    padding: 14px;
    border-radius: var(--radius-xl);
    background: color-mix(in srgb, var(--accent) 5%, var(--bg-primary));
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--text-primary) 6%, transparent);
  }

  .component-card.wide {
    grid-column: 1 / -1;
  }

  .component-card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-bold);
  }

  .sidebar-demo {
    display: grid;
    gap: 4px;
    min-width: 0;
    width: min(340px, 100%);
    padding: 8px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--sidebar-bg) 64%, var(--bg-primary));
  }

  .folder-demo-children {
    display: grid;
    gap: 4px;
    margin: -1px 0 0 20px;
    padding: 2px 0 0 8px;
    border-left: 1px solid var(--text-primary-tint-12);
  }

  .panel-demo {
    overflow: hidden;
    border-radius: var(--radius-xl);
    background: color-mix(in srgb, var(--sidebar-bg) 72%, var(--bg-primary));
  }

  .panel-demo-body {
    padding: 0 12px 12px;
  }

  .download-panel-preview {
    display: grid;
    gap: 10px;
  }

  .download-panel-toolbar {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 8px;
    align-items: center;
  }

  .download-row {
    display: grid;
    grid-template-columns: 36px minmax(0, 1fr) auto;
    gap: 10px;
    align-items: center;
    padding: 10px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--bg-primary) 82%, transparent);
  }

  .download-row.active {
    background: color-mix(in srgb, var(--accent) 12%, var(--bg-primary));
  }

  .download-file-icon {
    display: grid;
    place-items: center;
    width: 34px;
    height: 34px;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--accent) 22%, var(--bg-primary));
    color: var(--text-primary);
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-bold);
  }

  .download-file-icon.muted {
    background: color-mix(in srgb, var(--text-primary) 9%, transparent);
  }

  .download-copy {
    display: grid;
    gap: 4px;
    min-width: 0;
  }

  .download-copy strong {
    overflow: hidden;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .download-copy span {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .download-progress-track {
    height: 5px;
    overflow: hidden;
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-10);
  }

  .download-progress-fill {
    width: 43%;
    height: 100%;
    border-radius: inherit;
    background: var(--accent);
  }

  .sheet-demo-stage {
    position: relative;
    min-height: 176px;
    overflow: hidden;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--sidebar-bg) 72%, var(--bg-primary));
  }

  .control-demo {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }

  .control-demo.inline {
    justify-content: flex-start;
  }

  .extension-pattern-card {
    display: grid;
    grid-template-columns: 42px minmax(0, 1fr) auto;
    gap: 12px;
    align-items: center;
    padding: 12px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--bg-primary) 80%, transparent);
  }

  .extension-pattern-icon {
    display: grid;
    place-items: center;
    width: 42px;
    height: 42px;
    border-radius: var(--radius-md);
    background: linear-gradient(145deg, #96f0cc, #7c8cff);
    color: #141826;
    font-size: var(--font-size-2xl);
    font-weight: var(--font-weight-bold);
  }

  .extension-pattern-copy {
    display: grid;
    gap: 4px;
    min-width: 0;
  }

  .extension-pattern-copy strong,
  .diagnostics-stat-grid strong {
    color: var(--text-primary);
    font-size: var(--font-size-md);
  }

  .extension-pattern-copy span,
  .diagnostics-stat-grid span {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .extension-pattern-badges {
    display: flex;
    gap: 4px;
    flex-wrap: wrap;
  }

  .diagnostics-pattern {
    display: grid;
    gap: 10px;
  }

  .diagnostics-stat-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
  }

  .diagnostics-stat-grid div {
    display: grid;
    gap: 4px;
    padding: 12px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--bg-primary) 80%, transparent);
  }

  .diagnostics-log-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto auto;
    gap: 8px;
    align-items: center;
    padding: 10px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--bg-primary) 80%, transparent);
    color: var(--text-primary);
    font-size: var(--font-size-sm);
  }

  .token-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 10px;
  }

  .token-card {
    display: grid;
    gap: 6px;
    padding: 12px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--accent) 6%, var(--bg-primary));
  }

  .token-swatch {
    height: 34px;
    border-radius: var(--radius-md);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--text-primary) 9%, transparent);
  }

  .token-name {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  code {
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .layout-preview {
    display: grid;
    grid-template-columns: 220px minmax(0, 1fr);
    min-height: 220px;
    gap: 10px;
    padding: 10px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--accent) 6%, var(--bg-primary));
  }

  .layout-sidebar,
  .layout-content {
    display: grid;
    place-items: center;
    border-radius: var(--radius-lg);
    color: var(--text-muted);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .layout-sidebar {
    background: color-mix(in srgb, var(--sidebar-bg) 72%, var(--bg-primary));
  }

  .layout-content {
    background: color-mix(in srgb, var(--bg-primary) 82%, transparent);
  }

  .badge-row {
    display: flex;
    gap: 4px;
    justify-content: flex-end;
    flex-wrap: wrap;
  }
</style>
