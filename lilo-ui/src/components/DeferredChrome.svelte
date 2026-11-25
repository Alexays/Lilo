<!-- Everything the first paint never needs, split out of the entry chunk (lazy-imported by
     App.svelte once showDeferredChrome flips at visual-ready). Store init lives in stores/init.ts,
     so bridge events arriving before this chunk mounts are captured and render on mount. -->
<script lang="ts">
  import CommandBar from "./commandbar/CommandBar.svelte";
  import OnboardingShell from "./onboarding/OnboardingShell.svelte";
  import ContextTips from "./onboarding/ContextTips.svelte";
  import NoticeCapsule from "./banners/NoticeCapsule.svelte";
  import UndoToast from "./page/UndoToast.svelte";
  import FindBar from "./page/FindBar.svelte";
  import HoverLinkBar from "./page/HoverLinkBar.svelte";
  import ErrorPage from "./page/ErrorPage.svelte";
  import ContentPlaceholder from "./page/ContentPlaceholder.svelte";
  import PageHangCard from "./page/PageHangCard.svelte";
  import ScreenshotEditor from "./screenshot/ScreenshotEditor.svelte";
  import CaptureCard from "./screenshot/CaptureCard.svelte";
  import DownloadStack from "./downloads/DownloadStack.svelte";
  import TabSharePicker from "./page/TabSharePicker.svelte";
  import TabPreviewCard from "./sidebar/TabPreviewCard.svelte";
  import TabSwitcher from "./sidebar/TabSwitcher.svelte";
  import SidebarLinkDrop from "./sidebar/SidebarLinkDrop.svelte";
  import WhatsNewHost from "./whatsnew/WhatsNewHost.svelte";
  import AgentConnectModal from "./agents/AgentConnectModal.svelte";
  import ErrorBoundary from "./ui/ErrorBoundary.svelte";
  import { getPageShell, isClearBrowsingDataOpen, isDesignSystemShellOpen, reportPageShellState } from "../stores/panels.svelte";
  import { getSetting } from "../stores/settings.svelte";
  import { getSplitPanes } from "../stores/splitPanes.svelte";
  import { getActiveTab, getTabsById } from "../stores/tabs.svelte";
  import { on } from "../lib/bridge";
  import type { BridgeSplitPaneFrame } from "../lib/bridge/protocol";
  import { isAskBarOpen } from "../stores/conversations.svelte";

  // Latched on first open: the chunk loads once, then the component stays mounted so its own
  // open gate keeps close animations and later opens intact.
  let designSystemLoaded = $state(false);
  $effect(() => {
    if (isDesignSystemShellOpen()) designSystemLoaded = true;
  });
  // The system screens load on their first open, and stay for their close animation.
  const lazyShells = {
    settings: () => import("./settings/SettingsShell.svelte"),
    history: () => import("./history/HistoryShell.svelte"),
    downloads: () => import("./downloads/DownloadsShell.svelte"),
    processes: () => import("./diagnostics/ProcessManagerShell.svelte"),
    diagnostics: () => import("./diagnostics/DiagnosticsShell.svelte"),
  };
  let shellsLoaded = $state<(keyof typeof lazyShells)[]>([]);
  $effect(() => {
    const shell = getPageShell();
    if (shell && !shellsLoaded.includes(shell)) shellsLoaded = [...shellsLoaded, shell];
    // ⌘W closes the open system screen before the tab behind it; native learns the state here.
    reportPageShellState();
  });
  let askBarLoaded = $state(false);
  $effect(() => {
    if (isAskBarOpen()) askBarLoaded = true;
  });

  const agentsEnabled = $derived(getSetting("agentsEnabled", "false") === "true");
  // The panes showing a conversation: the agent panes of the split on screen, or the active tab.
  const agentPanes = $derived.by((): BridgeSplitPaneFrame[] => {
    if (!agentsEnabled) return [];
    const split = getSplitPanes();
    if (split.length > 0) {
      const tabs = getTabsById();
      return split.filter((pane) => tabs.get(pane.tabId)?.kind === "agent");
    }
    const tab = getActiveTab();
    return tab?.kind === "agent" ? [{ tabId: tab.id, x: 0, y: 0, width: 1, height: 1 }] : [];
  });
  // Mini conversation cards: the conversation's tab id by the page tab it floats over. Held here, out of
  // the first frame: a card only follows an Ask bar start.
  const conversationCards: Record<string, string> = $state({});
  on("openConversationCard", (data) => {
    conversationCards[data.sourceTabId] = data.tabId;
  });
  // A mini conversation shows over the page it was asked from, while that page is active and the conversation lives.
  const conversationCard = $derived.by(() => {
    const tab = agentsEnabled ? getActiveTab() : undefined;
    const tabId = tab && conversationCards[tab.id];
    const conversation = tabId ? getTabsById().get(tabId) : undefined;
    return tab && conversation && !conversation.isClosed ? { sourceTabId: tab.id, tabId: conversation.id } : null;
  });
</script>

<ErrorBoundary><CommandBar /></ErrorBoundary>
{#each shellsLoaded as shell (shell)}
  {#await lazyShells[shell]() then module}
    <ErrorBoundary><module.default /></ErrorBoundary>
  {/await}
{/each}
<ErrorBoundary><OnboardingShell /></ErrorBoundary>
<ContextTips />
<DownloadStack />
<WhatsNewHost />
<!-- Design System showcase is a contributor tool. Shipped in every build so it's reachable from
     installed/release apps too; self-gates via its UiShellFrame `active`.
     Lazy-imported on first open: it never renders at startup. -->
{#if designSystemLoaded}
  {#await import("./diagnostics/DesignSystemShell.svelte") then shell}
    <shell.default />
  {/await}
{/if}
<NoticeCapsule />
<UndoToast />
<FindBar />
<HoverLinkBar />
<TabSharePicker />
<AgentConnectModal />
{#if isClearBrowsingDataOpen()}
  {#await import("./settings/SettingsBrowsingData.svelte") then sheet}
    <sheet.default />
  {/await}
{/if}
<TabPreviewCard />
<TabSwitcher />
<SidebarLinkDrop />
<ErrorPage />
<ContentPlaceholder />
<!-- Agent conversations load only once the setting is on and something shows them. -->
{#if agentPanes.length > 0}
  {#await import("./agents/ConversationView.svelte") then view}
    {#each agentPanes as pane (pane.tabId)}
      <view.default tabId={pane.tabId} frame={pane} />
    {/each}
  {/await}
{/if}
{#each conversationCard ? [conversationCard] : [] as card (card.tabId)}
  {#await import("./agents/ConversationCard.svelte") then module}
    <module.default tabId={card.tabId} onclose={() => delete conversationCards[card.sourceTabId]} />
  {/await}
{/each}
{#if agentsEnabled && askBarLoaded}
  {#await import("./agents/AskBar.svelte") then askBar}
    <askBar.default />
  {/await}
{/if}
<PageHangCard />
<!-- Eager on purpose: it registers the screenshot flattener exactly once at mount, and the
     sidebar's Save/Copy buttons rely on that being live from the very first capture. -->
<ScreenshotEditor />
<CaptureCard />

