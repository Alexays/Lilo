<script lang="ts">
  import { untrack } from "svelte";
  import { announce } from "../../lib/announce";
  import { t } from "../../lib/i18n/state.svelte";
  import { getAgentsSpaceIds } from "../../stores/agents.svelte";
  import { getOnboarding } from "../../stores/onboarding.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { getActiveTab, getOpenTabs } from "../../stores/tabs.svelte";

  // Each tip shows once, as a toast, the first time the person does what it is about.
  const TIPS = {
    search: "onboarding.tips.search",
    split: "onboarding.tips.split",
    inspector: "onboarding.devTips.inspector",
    localhost: "onboarding.devTips.localhost",
    agents: "onboarding.devTips.agents",
  } as const;
  type Tip = keyof typeof TIPS;
  const LOCAL_HOST = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\]|[^/:]+\.localhost)(:\d+)?(\/|$)/i;

  const onboarding = getOnboarding();
  // The onboarding leaves the key empty when it ends; without it (never onboarded here) no tip shows.
  const seen = $derived(getSetting("seenTips", "*"));
  const active = $derived(seen !== "*" && !onboarding.visible);
  const pending = (tip: Tip): boolean => active && !seen.split(",").includes(tip);

  let queue: Tip[] = [];
  let shown = $state<Tip | null>(null);

  function want(tip: Tip): void {
    if (shown === tip || queue.includes(tip)) return;
    queue.push(tip);
    if (!shown) next();
  }

  function next(): void {
    const tip = queue.shift() ?? null;
    shown = tip;
    if (!tip) return;
    setSetting("seenTips", [...seen.split(",").filter(Boolean), tip].join(","));
    announce(t(TIPS[tip]));
    setTimeout(next, 5000);
  }

  // A new tab in the Space on screen, then a third one: the shortcut, then the split.
  let last = { spaceId: "", count: 0 };
  $effect(() => {
    if (!pending("search") && !pending("split")) return;
    const spaceId = getActiveSpaceId();
    const count = getOpenTabs(spaceId).length;
    untrack(() => {
      if (spaceId === last.spaceId && count > last.count && pending("search")) want("search");
      if (count >= 3 && pending("split")) want("split");
    });
    last = { spaceId, count };
  });

  // A local server: the Web Inspector, then the page beside another.
  $effect(() => {
    if (!pending("inspector") && !pending("localhost")) return;
    if (!LOCAL_HOST.test(getActiveTab()?.url ?? "")) return;
    const others = getOpenTabs().length > 1;
    untrack(() => {
      if (pending("inspector")) want("inspector");
      if (others && pending("localhost")) want("localhost");
    });
  });

  $effect(() => {
    if (pending("agents") && getAgentsSpaceIds().length > 0) untrack(() => want("agents"));
  });
</script>

{#if shown}
  {#key shown}<div class="tip" aria-hidden="true">{t(TIPS[shown])}</div>{/key}
{/if}

<style>
  /* A toast: a capsule at the bottom center of the page, under the pointer's way. */
  .tip { position: fixed; z-index: 55; pointer-events: none; bottom: calc(var(--chrome-content-bottom) + 24px);
    left: calc(var(--chrome-content-left-visible) + 16px); right: calc(var(--chrome-content-right) + 16px); width: fit-content; max-width: 480px; margin-inline: auto;
    padding: 8px 16px; border-radius: var(--radius-chip); background: var(--chrome-overlay-surface-strong); border: 1px solid var(--chrome-overlay-border);
    box-shadow: var(--chrome-overlay-shadow); color: var(--text-primary); font-size: var(--font-size-md); text-align: center;
    animation: tip-in var(--motion-duration-normal) var(--motion-ease-standard) both; }
  @keyframes tip-in { from { opacity: 0; transform: translateY(8px); } }
  @media (prefers-reduced-motion: reduce) { .tip { animation: tip-fade .15s both; } @keyframes tip-fade { from { opacity: 0; } } }
</style>
