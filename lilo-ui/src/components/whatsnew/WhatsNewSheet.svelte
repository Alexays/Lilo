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
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { acknowledgeWhatsNew, type WhatsNewRequest } from "../../stores/whatsNew.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiModal from "../ui/UiModal.svelte";
  import WhatsNewArt from "./WhatsNewArt.svelte";

  let { request, onclose }: { request: WhatsNewRequest; onclose: () => void } = $props();
  let release = $state.raw<ReleaseNotes | null | undefined>(undefined);
  const groups = $derived(request.version === release?.version ? release.groups : []);
  const count = $derived(groups.reduce((sum, group) => sum + group.entries.length, 0));
  const editorial = $derived(count ? release?.editorial?.[getLocale()] ?? release?.editorial?.en : null);
  const date = $derived(request.version === release?.version && release.date
    ? new Intl.DateTimeFormat(getLocale(), { dateStyle: "long", timeZone: "UTC" }).format(new Date(`${release.date}T00:00:00Z`)) : "");
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

{#if shown}
  <UiModal zone="whats-new" width={640} scrolls oncancel={onclose} ondefault={onclose} onbackdrop={onclose}>
    {#snippet children(titleId)}
      <div class="release-meta">
        <span class="release-version">{t("whatsNew.version", { version: request.version })}</span>
        {#if date}<span>{date}</span>{/if}
      </div>
      <h2 id={titleId}>{editorial?.headline ?? t("whatsNew.title")}</h2>
      <p class="release-intro">{editorial?.description ?? t("whatsNew.description")}</p>

      {#if editorial}
        <div class="release-highlights">
          {#each editorial.highlights as highlight, index (index)}
            <article class="release-highlight">
              <WhatsNewArt kind={highlight.illustration} />
              <h3>{highlight.title}</h3>
              <p>{highlight.description}</p>
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
    {/snippet}
    {#snippet leading()}<span class="release-reopen">{t("whatsNew.reopen")}</span>{/snippet}
    {#snippet actions()}<UiButton variant="primary" onclick={onclose}>{t("whatsNew.continue")}</UiButton>{/snippet}
  </UiModal>
{/if}

<style>
  .release-meta { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-8); color: var(--text-secondary); font-size: var(--font-size-sm); }
  .release-version { padding: 2px 8px; border-radius: var(--radius-chip); background: var(--accent-tint-14); color: var(--accent-ink); font-weight: var(--font-weight-medium); font-variant-numeric: tabular-nums; }
  h2 { margin: var(--space-16) 0 var(--space-4); font-size: var(--font-size-modal); line-height: 1.3; font-weight: var(--font-weight-semibold); overflow-wrap: anywhere; }
  .release-intro { margin: 0; color: var(--text-secondary); }
  .release-highlights { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: var(--space-12); margin-top: var(--space-20); }
  .release-highlight { padding: var(--space-8) var(--space-8) var(--space-16); border: 1px solid var(--separator); border-radius: var(--radius-md); background: var(--bg-hover); }
  .release-highlight h3 { margin: var(--space-12) var(--space-8) var(--space-4); }
  .release-highlight p { margin: 0 var(--space-8); color: var(--text-secondary); font-size: var(--font-size-sm); line-height: 1.5; }
  h3 { margin: 0 0 var(--space-6); font-size: var(--font-size-md); font-weight: var(--font-weight-semibold); line-height: 1.3; }
  .release-notes { margin-top: var(--space-16); }
  summary { padding: var(--space-4) 0; cursor: pointer; font-weight: var(--font-weight-medium); border-radius: var(--radius-xs); }
  summary span { color: var(--text-secondary); font-weight: var(--font-weight-regular); }
  summary:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
  .release-notes-content { padding-top: var(--space-12); }
  .release-source { margin: 0 0 var(--space-16); color: var(--text-secondary); font-size: var(--font-size-sm); }
  ul { margin: 0 0 var(--space-16); padding-left: var(--space-20); }
  li { margin: var(--space-8) 0; line-height: 1.5; white-space: pre-line; overflow-wrap: anywhere; }
  .release-unavailable { margin: var(--space-16) 0 0; color: var(--text-secondary); }
  .release-reopen { flex: 1; min-width: 120px; line-height: 1.4; }
</style>
