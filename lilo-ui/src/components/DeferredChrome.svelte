<!-- Everything the first paint never needs, split out of the entry chunk (lazy-imported by
     App.svelte once showDeferredChrome flips at visual-ready). Store init lives in stores/init.ts,
     so bridge events arriving before this chunk mounts are captured and render on mount. -->
<script lang="ts">
  import CommandBar from "./commandbar/CommandBar.svelte";
  import SettingsShell from "./settings/SettingsShell.svelte";
  import HistoryShell from "./history/HistoryShell.svelte";
  import OnboardingShell from "./onboarding/OnboardingShell.svelte";
  import CrashRecoveryBanner from "./banners/CrashRecoveryBanner.svelte";
  import SessionRestoreDegradedBanner from "./banners/SessionRestoreDegradedBanner.svelte";
  import ExtensionDebuggerBanner from "./banners/ExtensionDebuggerBanner.svelte";
  import FindBar from "./page/FindBar.svelte";
  import HoverLinkBar from "./page/HoverLinkBar.svelte";
  import ErrorPage from "./page/ErrorPage.svelte";
  import ContentPlaceholder from "./page/ContentPlaceholder.svelte";
  import PageHangCard from "./page/PageHangCard.svelte";
  import ScreenshotEditor from "./screenshot/ScreenshotEditor.svelte";
  import CaptureCard from "./screenshot/CaptureCard.svelte";
  import TabSharePicker from "./page/TabSharePicker.svelte";
  import TabPreviewCard from "./sidebar/TabPreviewCard.svelte";
  import TabSwitcher from "./sidebar/TabSwitcher.svelte";
  import WhatsNewHost from "./whatsnew/WhatsNewHost.svelte";
  import { isDesignSystemShellOpen } from "../stores/panels.svelte";
  import { isSidebarVisible } from "../stores/ui.svelte";

  // Latched on first open: the chunk loads once, then the component stays mounted so its own
  // open gate keeps close animations and later opens intact.
  let designSystemLoaded = $state(false);
  $effect(() => {
    if (isDesignSystemShellOpen()) designSystemLoaded = true;
  });
</script>

<CommandBar />
<SettingsShell />
<HistoryShell />
<OnboardingShell />
<WhatsNewHost />
<!-- Design System showcase is a contributor tool. Shipped in every build so it's reachable from
     installed/release apps too; self-gates via its UiShellFrame `active`.
     Lazy-imported on first open: it never renders at startup. -->
{#if designSystemLoaded}
  {#await import("./diagnostics/DesignSystemShell.svelte") then shell}
    <shell.default />
  {/await}
{/if}
<!-- Single fixed host over the page so simultaneous banners stack instead of overlapping; each
     banner still gates its own visibility. -->
<div class="banner-host chrome-content-overlay-root" class:sidebar-hidden={!isSidebarVisible()}>
  <CrashRecoveryBanner />
  <SessionRestoreDegradedBanner />
  <ExtensionDebuggerBanner />
</div>
<FindBar />
<HoverLinkBar />
<TabSharePicker />
<TabPreviewCard />
<TabSwitcher />
<ErrorPage />
<ContentPlaceholder />
<PageHangCard />
<!-- Eager on purpose: it registers the screenshot flattener exactly once at mount, and the
     sidebar's Save/Copy buttons rely on that being live from the very first capture. -->
<ScreenshotEditor />
<CaptureCard />

<style>
  .banner-host {
    bottom: auto;
    padding: 8px 16px 0;
    /* One centered column as wide as the widest banner: stacked banners line up. */
    display: grid;
    justify-content: center;
    gap: 8px;
    z-index: 10000;
  }
</style>
