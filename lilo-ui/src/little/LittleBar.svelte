<!-- The Little window's page view: the strip beside the traffic lights, over the Space's color. -->
<script lang="ts">
  import Icon from "../components/ui/Icon.svelte";
  import UiSplitButton from "../components/ui/UiSplitButton.svelte";
  import { reportInteractiveZone } from "../lib/actions/interactiveZone";
  import { announce } from "../lib/announce";
  import { chromeActions, littleActions } from "../lib/bridge/actions";
  import type { BridgeLittleState } from "../lib/bridge";
  import { t } from "../lib/i18n/state.svelte";
  import { openCommandBar } from "../stores/commandBar.svelte";

  let { little }: { little: BridgeLittleState } = $props();

  const COPIED_MS = 1400;
  let copied = $state(false);
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;

  const address = $derived.by(() => {
    try {
      const url = new URL(little.url);
      return url.protocol === "http:" || url.protocol === "https:" ? url.host.replace(/^www\./, "") : little.url;
    } catch {
      return little.url;
    }
  });
  const spaceName = $derived(`${little.space.icon} ${little.space.name}`.trim());

  function copyLink() {
    littleActions.copyLink();
    copied = true;
    announce(t("little.linkCopied"));
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copied = false), COPIED_MS);
  }

  function startDrag(event: PointerEvent) {
    if (event.button !== 0 || (event.target as HTMLElement).closest("button")) return;
    chromeActions.startWindowDrag();
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="little-bar tabs-surface"
  style:padding-left="{little.leadingInset}px"
  use:reportInteractiveZone={{ id: "little-bar" }}
  onpointerdown={startDrag}
>
  <button type="button" class="address" title={little.url} aria-label={t("commandBar.inputLabel")} onclick={() => openCommandBar(little.url, false, true)}>
    <Icon name="search" size={14} />
    <span class="host">{address}</span>
  </button>
  <button type="button" class="icon-button" title={t("little.copyLink")} aria-label={t("little.copyLink")} onclick={copyLink}>
    <Icon name={copied ? "check" : "copy"} size={16} />
  </button>
  <UiSplitButton
    menuLabel={t("little.openInMenu")}
    variants={little.otherSpaces.map((space) => ({
      label: t("little.openIn", { space: `${space.icon} ${space.name}`.trim() }),
      onclick: () => littleActions.openInSpace(space.id),
    }))}
    onclick={() => littleActions.openInSpace()}
  >
    {t("little.openIn", { space: spaceName })}<kbd class="keycap">⌘O</kbd>
  </UiSplitButton>
  <div class="progress" class:loading={little.loading} aria-hidden="true"></div>
</div>

<style>
  .little-bar {
    position: fixed;
    inset: 0 0 auto 0;
    display: flex;
    align-items: center;
    gap: var(--space-8);
    height: 52px;
    padding-right: var(--space-12);
    background: transparent;
  }

  .address {
    display: flex;
    flex: 1 1 auto;
    align-items: center;
    justify-content: center;
    gap: var(--space-6);
    min-width: 96px;
    height: var(--control-height-lg);
    padding: 0 var(--space-12);
    border: 0;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--sidebar-contrast) 8%, transparent);
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-md);
    cursor: text;
  }
  .address:hover { background: color-mix(in srgb, var(--sidebar-contrast) 14%, transparent); }
  .address:focus-visible,
  .icon-button:focus-visible { outline: var(--focus-outline); }
  .host {
    min-width: 0;
    overflow: hidden;
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .icon-button {
    display: grid;
    flex: none;
    place-items: center;
    width: var(--control-height-lg);
    height: var(--control-height-lg);
    padding: 0;
    border: 0;
    border-radius: var(--radius-md);
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
  }
  .icon-button:hover { background: color-mix(in srgb, var(--sidebar-contrast) 10%, transparent); color: var(--text-primary); }

  /* On the accent button the shortcut is part of its label, not a key cap of its own. */
  .keycap {
    min-width: 0;
    height: auto;
    margin-left: var(--space-6);
    padding: 0;
    background: transparent;
    box-shadow: none;
    color: inherit;
    line-height: inherit;
    opacity: 0.75;
  }

  /* One line along the strip's foot: a quiet sweep while loading, still under Reduce motion. */
  .progress {
    position: absolute;
    inset: auto 0 0 0;
    height: 2px;
    overflow: hidden;
    opacity: 0;
  }
  .progress.loading { opacity: 1; }
  .progress::before {
    content: "";
    display: block;
    width: 35%;
    height: 100%;
    background: var(--accent);
    animation: little-sweep 1.2s ease-in-out infinite;
  }
  @keyframes little-sweep {
    from { transform: translateX(-100%); }
    to { transform: translateX(300%); }
  }
  @media (prefers-reduced-motion: reduce) {
    .progress::before { width: 100%; animation: none; }
  }
</style>
