<script module lang="ts">
  import type { ReleaseNotes } from "./releaseNotes";
  import sheetCatalog from "../../lib/i18n/locales/en.json?raw";
  import { catalogs } from "../../lib/i18n/translate";

  catalogs.en = { ...catalogs.en, whatsNew: JSON.parse(sheetCatalog).whatsNew };

  const releaseResource: Promise<ReleaseNotes | null> = fetch("/release-notes.json")
    .then(async (response) => response.ok ? await response.json() as ReleaseNotes : null)
    .catch(() => null);
</script>

<script lang="ts">
  import { onMount, tick } from "svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { acknowledgeWhatsNew, type WhatsNewRequest } from "../../stores/whatsNew.svelte";
  import WhatsNewArt from "./WhatsNewArt.svelte";
  import WhatsNewRecording from "./WhatsNewRecording.svelte";

  let { request, onclose }: { request: WhatsNewRequest; onclose: () => void } = $props();
  const titleId = $props.id();
  let release = $state.raw<ReleaseNotes | null>(null);
  const groups = $derived(request.version === release?.version ? release.groups : []);
  const count = $derived(groups.reduce((sum, group) => sum + group.entries.length, 0));
  const editorial = $derived(count ? release?.editorial?.[getLocale()] ?? release?.editorial?.en : null);
  const date = $derived(request.version === release?.version && release.date
    ? new Intl.DateTimeFormat(getLocale(), { dateStyle: "long", timeZone: "UTC" }).format(new Date(`${release.date}T00:00:00Z`)) : "");
  let dialog: HTMLDialogElement;
  let heading: HTMLHeadingElement;
  // Matches the leave animation below.
  const CLOSE_MS = 160;
  let closing = $state(false);
  let closeTimer: ReturnType<typeof setTimeout> | undefined;

  onMount(() => {
    let cancelled = false;
    let opener: HTMLElement | null = null;
    void (async () => {
      const loaded = await releaseResource;
      if (cancelled) return;
      release = loaded;
      if (request.automatic && count === 0) { onclose(); return; }
      await tick();
      if (cancelled) return;
      opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      dialog.showModal();
      heading.focus({ preventScroll: true });
      acknowledgeWhatsNew(request.version);
    })();
    return () => {
      cancelled = true;
      clearTimeout(closeTimer);
      dialog.close();
      if (opener?.isConnected) opener.focus({ preventScroll: true });
    };
  });

  function close(): void {
    if (closing) return;
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) { onclose(); return; }
    closing = true;
    // A timer, not animationend: reduced power turns the animation off.
    closeTimer = setTimeout(onclose, CLOSE_MS);
  }

  function handleKeydown(event: KeyboardEvent): void {
    event.stopPropagation();
    if (event.key === "Escape") { event.preventDefault(); close(); return; }
    if (event.key !== "Tab") return;
    const controls = [...dialog.querySelectorAll<HTMLElement>("button:not([disabled]), summary")];
    const index = controls.indexOf(document.activeElement as HTMLElement);
    const next = event.shiftKey ? (index <= 0 ? controls.length - 1 : index - 1) : (index + 1) % controls.length;
    event.preventDefault();
    controls[next]?.focus();
  }
</script>

<dialog
  bind:this={dialog}
  class="whats-new"
  class:closing
  aria-labelledby={titleId}
  tabindex="-1"
  oncancel={(event) => { event.preventDefault(); close(); }}
  onclick={(event) => { if (event.target === dialog) close(); }}
  onkeydown={handleKeydown}
  use:reportInteractiveZone={{ id: "whats-new" }}
>
  <div class="whats-new-stage">
    <section class="whats-new-sheet">
      <div class="whats-new-body">
        <header>
          <div class="release-meta">
            <span class="release-version">{t("whatsNew.version", { version: request.version })}</span>
            {#if date}<span>{date}</span>{/if}
          </div>
          <button type="button" class="release-close" aria-label={t("common.close")} onclick={close}>
            <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="m3 3 6 6m0-6-6 6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /></svg>
          </button>
          <h2 bind:this={heading} id={titleId} tabindex="-1">{editorial?.headline ?? t("whatsNew.title")}</h2>
          <p class="release-intro">{editorial?.description ?? t("whatsNew.description")}</p>
        </header>

        {#if editorial}
          <div class="release-highlights">
            {#each editorial.highlights as highlight, index (index)}
              <article class="release-highlight" class:recorded={!!highlight.media}>
                {#if !highlight.media}<WhatsNewArt kind={highlight.illustration} />{/if}
                <div>
                  <h3>{highlight.title}</h3>
                  <p>{highlight.description}</p>
                  {#if highlight.media}<WhatsNewRecording media={highlight.media} title={highlight.title} />{/if}
                </div>
              </article>
            {/each}
          </div>
        {/if}

        {#if count}
          <details class="release-notes" open={!editorial}>
            <summary>{t("whatsNew.allChanges")} <span>· {t("whatsNew.changes", { count })}</span></summary>
            <div class="release-notes-content">
              <p class="release-source">{t("whatsNew.originalNotes")}</p>
              {#each groups as group, index (index)}
                <h3>{t(`whatsNew.kinds.${group.kind}`)}</h3>
                <ul>{#each group.entries as entry, entryIndex (entryIndex)}<li>{entry}</li>{/each}</ul>
              {/each}
            </div>
          </details>
        {:else}
          <p class="release-unavailable">{t("whatsNew.unavailable")}</p>
        {/if}
      </div>

      <footer>
        <span>{t("whatsNew.reopen")}</span>
        <button type="button" class="release-continue" onclick={close}>{t("whatsNew.continue")}</button>
      </footer>
    </section>
  </div>
</dialog>

<style>
  .release-highlight.recorded { grid-template-columns: minmax(0, 1fr); }
  .whats-new {
    position: fixed;
    inset: 0;
    width: 100vw;
    height: 100vh;
    max-width: none;
    max-height: none;
    margin: 0;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--text-primary);
    overflow: hidden;
  }
  .whats-new::backdrop {
    background: var(--chrome-overlay-backdrop-tint);
    animation: release-fade-in var(--motion-duration-normal) var(--motion-ease-standard) both;
  }
  .whats-new.closing::backdrop { animation: release-fade-out 160ms var(--motion-ease-standard) both; }
  .whats-new-stage {
    position: absolute;
    top: var(--chrome-content-top);
    right: var(--chrome-content-right);
    bottom: var(--chrome-content-bottom);
    left: var(--chrome-content-left-visible);
    display: grid;
    place-items: center;
    padding: var(--space-24);
    pointer-events: none;
  }
  .whats-new-sheet {
    position: relative;
    display: flex;
    flex-direction: column;
    width: min(560px, 100%);
    max-height: 100%;
    min-height: 0;
    border: 1px solid var(--border);
    border-radius: var(--radius-xl);
    background: var(--bg-elevated);
    box-shadow: var(--chrome-overlay-shadow);
    overflow: hidden;
    pointer-events: auto;
    animation: release-arrive var(--motion-duration-normal) var(--motion-ease-organic) both;
  }
  .whats-new.closing .whats-new-sheet { animation: release-leave 160ms var(--motion-ease-standard) both; pointer-events: none; }
  .whats-new-body { min-height: 0; padding: var(--space-24) var(--space-24) 0; overflow-y: auto; overscroll-behavior: contain; }
  header { position: relative; padding-bottom: var(--space-20); }
  .release-meta { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-8); padding-right: var(--space-24); color: var(--text-secondary); font-size: var(--font-size-xs); }
  .release-version { padding: 2px 7px; border-radius: var(--radius-xs); background: var(--accent-tint-14); color: var(--accent-ink); font-weight: var(--font-weight-medium); font-variant-numeric: tabular-nums; }
  .release-close { position: absolute; top: -8px; right: -8px; display: grid; place-items: center; width: 28px; height: 28px; padding: 0; border: 0; border-radius: var(--radius-chip); background: var(--bg-hover); color: var(--text-secondary); cursor: pointer; }
  .release-close:hover { color: var(--text-primary); background: var(--bg-tertiary); }
  h2 { margin: var(--space-16) 0 var(--space-8); font-size: var(--font-size-3xl); line-height: 1.2; font-weight: var(--font-weight-semibold); letter-spacing: -0.45px; outline: none; overflow-wrap: anywhere; }
  .release-intro { margin: 0; color: var(--text-secondary); font-size: var(--font-size-md); line-height: 1.5; }
  .release-highlight { display: grid; grid-template-columns: minmax(72px, 25%) minmax(0, 1fr); align-items: center; gap: var(--space-16); padding: var(--space-16) 0; border-top: 1px solid var(--separator); }
  h3 { margin: 0 0 var(--space-6); font-size: var(--font-size-lg); font-weight: var(--font-weight-semibold); line-height: 1.3; }
  .release-highlight p { margin: 0; color: var(--text-secondary); font-size: var(--font-size-sm); line-height: 1.5; }
  .release-notes { border-top: 1px solid var(--separator); padding-top: var(--space-12); font-size: var(--font-size-sm); }
  summary { padding: var(--space-4) 0; color: var(--text-secondary); cursor: pointer; font-weight: var(--font-weight-medium); }
  summary span { font-weight: var(--font-weight-regular); }
  .release-notes-content { padding-top: var(--space-12); }
  .release-source { margin: 0 0 var(--space-16); color: var(--text-secondary); font-size: var(--font-size-xs); }
  .release-notes h3 { font-size: var(--font-size-sm); }
  ul { margin: 0 0 var(--space-16); padding-left: var(--space-20); }
  li { margin: var(--space-8) 0; line-height: 1.5; white-space: pre-line; overflow-wrap: anywhere; }
  .release-unavailable { margin: var(--space-8) 0; font-size: var(--font-size-sm); color: var(--text-secondary); }
  footer { flex-shrink: 0; display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: var(--space-12); padding: var(--space-20) var(--space-24); }
  footer span { flex: 1; min-width: 120px; color: var(--text-secondary); font-size: var(--font-size-xs); line-height: 1.4; }
  .release-continue { flex-shrink: 0; padding: 7px 14px; border: 1px solid var(--accent-tint-22); border-radius: var(--radius-sm); background: var(--accent); color: var(--accent-text); font: inherit; font-size: var(--font-size-sm); font-weight: var(--font-weight-medium); box-shadow: var(--shadow-control); cursor: pointer; }
  .release-continue:hover { background: var(--accent-hover); }
  button:focus-visible, summary:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
  @keyframes release-arrive { from { opacity: 0; transform: translateY(6px) scale(0.985); } }
  @keyframes release-leave { to { opacity: 0; transform: translateY(4px) scale(0.985); } }
  @keyframes release-fade-in { from { opacity: 0; } }
  @keyframes release-fade-out { to { opacity: 0; } }
  @media (prefers-reduced-motion: reduce) { .whats-new-sheet, .whats-new::backdrop { animation: none; } }
  @media (max-height: 520px) { .whats-new-stage { padding: var(--space-12); } }
</style>
