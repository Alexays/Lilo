<script module lang="ts">
  import type { ReleaseEditorialCopy, ReleaseKind, ReleaseNotes } from "./releaseNotes";
  import sheetCatalog from "../../lib/i18n/locales/en.json?raw";
  import { catalogs } from "../../lib/i18n/translate";

  catalogs.en = { ...catalogs.en, whatsNew: JSON.parse(sheetCatalog).whatsNew };

  const releaseResource: Promise<ReleaseNotes | null> = fetch("/release-notes.json")
    .then(async (response) => response.ok ? await response.json() as ReleaseNotes : null)
    .catch(() => null);
</script>

<script lang="ts">
  import { getFormatLocale, getLocale, t } from "../../lib/i18n/state.svelte";
  import { acknowledgeWhatsNew, type WhatsNewRequest } from "../../stores/whatsNew.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiModal from "../ui/UiModal.svelte";
  import Fleuron from "../onboarding/Fleuron.svelte";
  import ReleaseMedia from "./ReleaseMedia.svelte";
  import WhatsNewArt from "./WhatsNewArt.svelte";

  const KIND_ICONS: Record<ReleaseKind, string> = {
    Breaking: "M6 2.5v4.5M6 9.2v.3",
    Added: "M6 2.5v7M2.5 6h7",
    Changed: "M6 1.5v2M6 8.5v2M1.5 6h2M8.5 6h2M2.8 2.8l1.4 1.4M7.8 7.8l1.4 1.4M9.2 2.8 7.8 4.2M4.2 7.8 2.8 9.2",
    Fixed: "m2.5 6.2 2.4 2.4 4.6-5",
  };

  let { request, onclose }: { request: WhatsNewRequest; onclose: () => void } = $props();
  let release = $state.raw<ReleaseNotes | null | undefined>(undefined);
  const groups = $derived(request.version === release?.version ? release.groups : []);
  const count = $derived(groups.reduce((sum, group) => sum + group.entries.length, 0));
  const editorial = $derived(count ? release?.editorial?.[getLocale()] ?? release?.editorial?.en : null);
  const date = $derived(request.version === release?.version && release.date
    ? new Intl.DateTimeFormat(getFormatLocale(), { dateStyle: "long", timeZone: "UTC" }).format(new Date(`${release.date}T00:00:00Z`)) : "");
  const shown = $derived(release !== undefined && !(request.automatic && count === 0));

  $effect(() => {
    let cancelled = false;
    void releaseResource.then((loaded) => { if (!cancelled) release = loaded; });
    return () => { cancelled = true; };
  });

  $effect(() => {
    if (release === undefined) return;
    if (shown) acknowledgeWhatsNew(request.version);
    else onclose();
  });
</script>

{#snippet visual(highlight: ReleaseEditorialCopy["highlights"][number])}
  {#if highlight.media}
    <div class="release-visual"><ReleaseMedia media={highlight.media} label={highlight.title} /></div>
  {:else if highlight.illustration}
    <div class="release-visual"><WhatsNewArt kind={highlight.illustration} /></div>
  {/if}
{/snippet}

{#if shown}
  <UiModal zone="whats-new" width={720} scrolls oncancel={onclose} ondefault={onclose} onbackdrop={onclose}>
    {#snippet children(titleId)}
      <header class="release-header">
        <div class="release-icon reveal"><Fleuron size={40} /></div>
        <p class="release-meta reveal" style:--i={1}>
          <span class="release-version">{t("whatsNew.version", { version: request.version })}</span>{#if date}<span class="release-dot" aria-hidden="true">·</span>{date}{/if}
        </p>
        <h2 id={titleId} class="reveal" style:--i={1}>{editorial?.headline ?? t("whatsNew.title")}</h2>
        <p class="release-intro reveal" style:--i={2}>{editorial?.description ?? t("whatsNew.description")}</p>
      </header>

      {#if editorial}
        {@const [hero, ...rest] = editorial.highlights}
        <article class="release-highlight release-hero reveal" class:drawn={!hero.media && hero.illustration} style:--i={3}>
          {@render visual(hero)}
          <h3>{hero.title}</h3>
          <p>{hero.description}</p>
        </article>
        {#if rest.length}
          <div class="release-highlights">
            {#each rest as highlight, index (index)}
              <article class="release-highlight reveal" style:--i={4 + index}>
                {@render visual(highlight)}
                <h3>{highlight.title}</h3>
                <p>{highlight.description}</p>
              </article>
            {/each}
          </div>
        {/if}
      {/if}

      {#if count}
        <details class="release-notes reveal" style:--i={editorial ? 6 : 3} open={!editorial}>
          <summary>
            {t("whatsNew.allChanges")} <span class="release-count">· {t("whatsNew.changes", { count })}</span>
            <svg class="release-chevron" viewBox="0 0 10 10" aria-hidden="true"><path d="M3 1.5 6.5 5 3 8.5" /></svg>
          </summary>
          <p class="release-source">{t("whatsNew.originalNotes")}</p>
          {#each groups as group, index (index)}
            <section class="release-group">
              <h3>
                <span class="release-badge {group.kind}" aria-hidden="true">
                  <svg viewBox="0 0 12 12"><path d={KIND_ICONS[group.kind]} /></svg>
                </span>
                {t(`whatsNew.kinds.${group.kind}`)}
              </h3>
              <ul>{#each group.entries as entry, entryIndex (entryIndex)}<li>{entry}</li>{/each}</ul>
            </section>
          {/each}
        </details>
      {:else}
        <p class="release-unavailable">{t("whatsNew.unavailable")}</p>
      {/if}
    {/snippet}
    {#snippet leading()}<span class="release-reopen">{t("whatsNew.reopen")}</span>{/snippet}
    {#snippet actions()}<UiButton variant="primary" onclick={onclose}>{t("whatsNew.continue")}</UiButton>{/snippet}
  </UiModal>
{/if}

<style>
  .release-header { text-align: center; padding-top: var(--space-8); }
  .release-icon { display: grid; place-items: center; width: 64px; height: 64px; margin: 0 auto var(--space-12); border-radius: var(--radius-xl); background: var(--bg-elevated); box-shadow: var(--shadow-sm), 0 0 0 0.5px var(--separator); }
  .release-meta { margin: 0; color: var(--text-secondary); font-size: var(--font-size-sm); font-variant-numeric: tabular-nums; }
  .release-version { color: var(--accent-ink); font-weight: var(--font-weight-semibold); }
  .release-dot { margin: 0 var(--space-6); }
  h2 { margin: var(--space-6) 0; font-size: var(--font-size-headline); line-height: 1.15; font-weight: var(--font-weight-bold); letter-spacing: -0.02em; overflow-wrap: anywhere; text-wrap: balance; }
  .release-intro { max-width: 30em; margin: 0 auto; color: var(--text-secondary); font-size: var(--font-size-body-lg); line-height: 1.45; text-wrap: balance; }

  .release-visual { position: relative; aspect-ratio: 16 / 9; overflow: hidden; border-radius: var(--radius-box); background: var(--bg-hover); }
  .release-visual::after { content: ""; position: absolute; inset: 0; border-radius: inherit; box-shadow: inset 0 0 0 0.5px var(--separator); pointer-events: none; }
  .release-hero { margin-top: var(--space-24); }
  .release-hero .release-visual { border-radius: var(--radius-lg); }
  .release-hero h3 { margin: var(--space-16) 0 var(--space-4); font-size: var(--font-size-modal); letter-spacing: -0.01em; }
  .release-hero p { max-width: 36em; font-size: var(--font-size-md); }
  /* A drawing is a small sketch: beside the text at the size the other highlights give it, films keep the full width. */
  .release-hero.drawn { display: grid; grid-template-columns: 240px 1fr; grid-template-rows: 1fr auto auto 1fr; column-gap: var(--space-24); }
  .release-hero.drawn .release-visual { grid-row: 1 / -1; }
  .release-hero.drawn h3 { grid-row: 2; margin-top: 0; }
  .release-hero.drawn p { grid-row: 3; }
  .release-highlights { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: var(--space-24); margin-top: var(--space-24); }
  .release-highlight h3 { margin: var(--space-12) 0 var(--space-2); }
  .release-highlight p { margin: 0; color: var(--text-secondary); font-size: var(--font-size-sm); line-height: 1.5; }
  h3 { margin: 0; font-size: var(--font-size-md); font-weight: var(--font-weight-semibold); line-height: 1.3; }

  .release-notes { margin-top: var(--space-24); border-top: 0.5px solid var(--separator); }
  summary { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-12) 0 var(--space-4); cursor: pointer; font-weight: var(--font-weight-semibold); list-style: none; border-radius: var(--radius-xs); }
  summary::-webkit-details-marker { display: none; }
  summary:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
  .release-count { color: var(--text-secondary); font-weight: var(--font-weight-regular); }
  .release-chevron { width: 10px; height: 10px; margin-left: auto; fill: none; stroke: var(--text-secondary); stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; transition: transform var(--motion-duration-normal) var(--motion-ease-standard); }
  .release-notes[open] .release-chevron { transform: rotate(90deg); }
  .release-source { margin: 0 0 var(--space-4); color: var(--text-secondary); font-size: var(--font-size-sm); }
  .release-group h3 { display: flex; align-items: center; gap: var(--space-8); margin: var(--space-16) 0 var(--space-8); color: var(--text-secondary); font-size: var(--font-size-sm); }
  .release-badge { display: grid; place-items: center; width: 20px; height: 20px; border-radius: var(--radius-sm); background: var(--accent); color: var(--accent-text); }
  .release-badge.Fixed { background: var(--success); color: var(--on-color); }
  .release-badge.Breaking { background: var(--danger-deep); color: var(--on-color); }
  .release-badge svg { width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }
  ul { margin: 0; padding: 0; list-style: none; border-radius: var(--radius-md); background: var(--bg-hover); }
  li { padding: var(--space-8) var(--space-12); line-height: 1.45; white-space: pre-line; overflow-wrap: anywhere; }
  li + li { border-top: 0.5px solid var(--separator); }
  .release-unavailable { margin: var(--space-16) 0 0; color: var(--text-secondary); text-align: center; }
  .release-reopen { flex: 1; min-width: 120px; line-height: 1.4; }

  .reveal { animation: release-rise 520ms var(--motion-ease-organic) both; animation-delay: calc(80ms + var(--i, 0) * 60ms); }
  @keyframes release-rise { from { opacity: 0; transform: translateY(10px); } }
  @media (prefers-reduced-motion: reduce) { .reveal { animation: none; } }
</style>
