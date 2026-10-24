<!-- A copied capture's card, floating in the page area's bottom-right corner like the macOS
     screenshot thumbnail: the thumbnail opens the capture in the editor, as Edit does. -->
<script lang="ts">
  import { fade, fly } from "svelte/transition";
  import { cubicIn, quintOut } from "svelte/easing";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { t } from "../../lib/i18n/state.svelte";
  import { ensureContrast, TEXT_CONTRAST } from "../../lib/sidebarTheme";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import {
    dismissCapture,
    editCapture,
    getCaptureCard,
    pauseCaptureCard,
    resumeCaptureCard,
    saveCapture,
  } from "../../stores/captureCard.svelte";

  const card = $derived(getCaptureCard());
  // White on the accent, darkened until it reads; only a very light accent keeps its dark label.
  const editFill = $derived.by(() => {
    if (!card) return "";
    const accent = document.documentElement.style.getPropertyValue("--sidebar-accent").trim();
    if (!accent || ensureContrast("#ffffff", accent, 2, "") !== "#ffffff") return "";
    return `--edit-fill: ${ensureContrast(accent, "#ffffff", TEXT_CONTRAST, accent)}; --edit-text: #ffffff`;
  });

  // As macOS's thumbnail: in from past the corner on a soft settle, out the same way, quicker.
  function enter(node: HTMLElement) {
    return prefersReducedMotion()
      ? fade(node, { duration: 150 })
      : fly(node, { x: node.offsetWidth + 24, opacity: 1, duration: 420, easing: quintOut });
  }

  function leave(node: HTMLElement) {
    return prefersReducedMotion()
      ? fade(node, { duration: 150 })
      : fly(node, { x: node.offsetWidth + 24, opacity: 1, duration: 240, easing: cubicIn });
  }

  const SWIPE_START_PX = 4;
  const SWIPE_DISMISS_PX = 48;
  let swipeFrom: number | null = null;
  let swipeX = $state(0);
  let swiping = $state(false);
  // The click that ends a swipe is not a press on what lies under it.
  let swallowClick = false;

  function onpointerdown(event: PointerEvent) {
    if (event.button === 0) swipeFrom = event.clientX;
  }

  function onpointermove(event: PointerEvent) {
    if (swipeFrom === null) return;
    const dx = Math.max(0, event.clientX - swipeFrom);
    if (!swiping && dx < SWIPE_START_PX) return;
    if (!swiping) (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    swiping = true;
    swipeX = dx;
  }

  function onpointerup() {
    swipeFrom = null;
    if (!swiping) return;
    swiping = false;
    swallowClick = true;
    setTimeout(() => (swallowClick = false));
    // The leaving card keeps its offset: its outro is paused against later state.
    if (swipeX >= SWIPE_DISMISS_PX) dismissCapture();
    swipeX = 0;
  }

  function onclickcapture(event: MouseEvent) {
    if (swallowClick) event.stopPropagation();
  }

  function onkeydown(event: KeyboardEvent) {
    if (event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    dismissCapture();
  }
</script>

<div class="capture-host chrome-content-overlay-root" class:sidebar-hidden={!isSidebarVisible()}>
  <!-- Mounted before the card so assistive tech announces each capture, a replacing one too. -->
  <p class="announce" role="status">
    {#if card}{#key card.seq}{t("screenshot.captureCopied")}{/key}{/if}
  </p>
  {#if card}
    <!-- Escape from any of its buttons and a swipe anywhere on it dismiss the whole card. -->
    <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
    <div
      class="capture-card float-surface"
      role="group"
      aria-label={t("screenshot.title")}
      class:swiping
      style:transform={swipeX ? `translateX(${swipeX}px)` : undefined}
      style:opacity={swipeX ? Math.max(0.3, 1 - swipeX / 240) : undefined}
      in:enter
      out:leave
      use:reportInteractiveZone={{ id: "capture-card" }}
      onmouseenter={pauseCaptureCard}
      onmouseleave={resumeCaptureCard}
      onfocusin={pauseCaptureCard}
      onfocusout={resumeCaptureCard}
      {onpointerdown}
      {onpointermove}
      {onpointerup}
      onpointercancel={onpointerup}
      {onclickcapture}
      {onkeydown}
    >
      <button type="button" class="thumb" aria-label={t("screenshot.editCapture")} onclick={editCapture}>
        <img src={card.thumbURL} alt="" draggable="false" />
        <span class="badge" aria-hidden="true">{t("screenshot.copiedBadge")}</span>
      </button>
      <div class="actions">
        <button type="button" class="action primary" style={editFill} onclick={editCapture}>{t("screenshot.edit")}</button>
        <button type="button" class="action" onclick={saveCapture}>{t("common.save")}</button>
        <button type="button" class="action dismiss" aria-label={t("screenshot.dismiss")} onclick={dismissCapture}>
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
            <path d="M1.5 1.5l7 7M8.5 1.5l-7 7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
          </svg>
        </button>
      </div>
    </div>
  {/if}
</div>

<style>
  .capture-host {
    z-index: 1002;
    display: flex;
    align-items: flex-end;
    justify-content: flex-end;
    padding: 12px;
    pointer-events: none;
  }

  .announce {
    position: absolute;
    width: 1px;
    height: 1px;
    margin: -1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }

  /* Shrinks with a narrow or short page area, never past it. */
  .capture-card {
    pointer-events: auto;
    box-sizing: border-box;
    width: min(208px, 100%);
    max-height: 100%;
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 8px;
    border-radius: var(--radius-lg);
    /* The deep, soft lift of the macOS screenshot thumbnail, over a hairline edge. */
    box-shadow:
      0 0 0 0.5px var(--float-border),
      0 18px 40px -12px color-mix(in srgb, black 38%, transparent),
      0 4px 12px color-mix(in srgb, black 12%, transparent);
    touch-action: pan-y;
    user-select: none;
    -webkit-user-select: none;
    transition:
      transform 260ms var(--motion-ease-spring),
      opacity 260ms var(--motion-ease-spring);
  }

  .capture-card.swiping {
    transition: none;
  }

  @media (prefers-color-scheme: dark) {
    .capture-card {
      box-shadow:
        0 0 0 0.5px var(--float-border),
        0 18px 44px -10px color-mix(in srgb, black 60%, transparent),
        0 4px 12px color-mix(in srgb, black 30%, transparent);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .capture-card {
      transition: none;
    }
  }

  /* Concentric with the card: its radius less the padding. */
  .thumb {
    position: relative;
    flex: 0 1 auto;
    min-height: 0;
    aspect-ratio: 16 / 10;
    padding: 0;
    border: 0;
    border-radius: calc(var(--radius-lg) - 8px);
    overflow: hidden;
    background: var(--bg-hover);
    cursor: pointer;
    transition: transform 160ms var(--motion-ease-standard);
  }

  .thumb:active {
    transform: scale(0.98);
  }

  .thumb img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: top;
  }

  .thumb:hover img {
    filter: brightness(0.94);
  }

  .badge {
    position: absolute;
    left: 6px;
    top: 6px;
    padding: 2px 8px;
    border-radius: var(--radius-chip);
    /* Fixed dark chip: it reads on any capture behind it. */
    background: color-mix(in srgb, var(--on-pastel) 78%, transparent);
    color: var(--on-color);
    font-size: var(--font-size-2xs);
    font-weight: 600;
  }

  .actions {
    display: flex;
    gap: 6px;
    min-width: 0;
  }

  .action {
    flex: 1 1 0;
    min-width: 0;
    height: 26px;
    padding: 0 6px;
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    cursor: pointer;
  }

  .action:hover {
    background: var(--bg-active);
  }

  .action.primary {
    background: var(--edit-fill, var(--accent));
    color: var(--edit-text, var(--accent-text));
  }

  /* Darker, so the label only gains contrast. */
  .action.primary:hover {
    background: color-mix(in srgb, var(--edit-fill, var(--accent)) 88%, black);
  }

  .action.dismiss {
    flex: 0 0 26px;
    padding: 0;
    display: grid;
    place-items: center;
  }

  .thumb:focus-visible,
  .action:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
