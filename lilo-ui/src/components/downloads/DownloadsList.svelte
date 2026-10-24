<script lang="ts">
  import { tick } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import DownloadRow from "./DownloadRow.svelte";
  import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import type { GroupedDownloads } from "./downloadsPanelModel";

  interface Props {
    groups: GroupedDownloads;
    hasAnyDownloads: boolean;
    hasFilteredResults: boolean;
    selectedId: number | null;
    onselect: (id: number) => void;
    onmenu: (download: BridgeDownloadSnapshot, anchor: DOMRect) => void;
  }

  let {
    groups,
    hasAnyDownloads,
    hasFilteredResults,
    selectedId,
    onselect,
    onmenu,
  }: Props = $props();

  let bodyEl: HTMLDivElement | undefined = $state();
  let showTopScrollCue = $state(false);
  let showBottomScrollCue = $state(false);

  function updateScrollCues() {
    const element = bodyEl;
    if (!element) {
      showTopScrollCue = false;
      showBottomScrollCue = false;
      return;
    }
    const maxScrollTop = Math.max(0, element.scrollHeight - element.clientHeight);
    showTopScrollCue = element.scrollTop > 10;
    showBottomScrollCue = maxScrollTop - element.scrollTop > 10;
  }

  $effect(() => {
    void groups;
    void tick().then(updateScrollCues);
  });
</script>

<div class="downloads-scroll-shell">
  <div class="downloads-body" bind:this={bodyEl} onscroll={updateScrollCues}>
    {#if !hasAnyDownloads}
      <div class="empty-state">
        <div class="empty-title">{t("downloadsPanel.emptyTitle")}</div>
        <div class="empty-copy">{t("downloadsPanel.emptyCopy")}</div>
      </div>
    {:else if !hasFilteredResults}
      <div class="empty-state">
        <div class="empty-title">{t("downloadsPanel.noResults")}</div>
      </div>
    {:else}
      {#if groups.active.length > 0}
        <section class="download-group" aria-label={t("downloadsPanel.activeGroupAriaLabel")}>
          <div class="download-group-title">{t("downloadsPanel.activeGroupTitle")}</div>
          {#each groups.active as dl (dl.id)}
            <DownloadRow
              download={dl}
              selected={selectedId === dl.id}
              onselect={() => onselect(dl.id)}
              onmenu={(anchor) => onmenu(dl, anchor)}
            />
          {/each}
        </section>
      {/if}

      {#each groups.history as group (group.key)}
        {@const label = group.labelKey ? t(group.labelKey) : group.label}
        <section class="download-group" aria-label={label}>
          <div class="download-group-title">{label}</div>
          {#each group.items as dl (dl.id)}
            <DownloadRow
              download={dl}
              selected={selectedId === dl.id}
              onselect={() => onselect(dl.id)}
              onmenu={(anchor) => onmenu(dl, anchor)}
            />
          {/each}
        </section>
      {/each}
    {/if}
  </div>

  <div class="downloads-scroll-gradient top" class:visible={showTopScrollCue}></div>
  <div class="downloads-scroll-gradient bottom" class:visible={showBottomScrollCue}></div>
</div>

<style>
  .downloads-scroll-shell {
    position: relative;
    flex: 1;
    min-height: 0;
  }

  .downloads-body {
    height: 100%;
    overflow-y: auto;
    padding: 0 8px 10px;
  }

  .downloads-scroll-gradient {
    position: absolute;
    left: 8px;
    right: 8px;
    height: 16px;
    opacity: 0;
    pointer-events: none;
    transition: opacity var(--motion-duration-normal) ease;
  }

  .downloads-scroll-gradient.visible {
    opacity: 1;
  }

  .downloads-scroll-gradient.top {
    top: 0;
    background: linear-gradient(180deg,
      color-mix(in srgb, var(--bg-primary) 92%, transparent),
      color-mix(in srgb, var(--bg-primary) 0%, transparent));
  }

  .downloads-scroll-gradient.bottom {
    bottom: 10px;
    background: linear-gradient(0deg,
      color-mix(in srgb, var(--bg-primary) 94%, transparent),
      color-mix(in srgb, var(--bg-primary) 0%, transparent));
  }

  .empty-state {
    display: grid;
    justify-items: center;
    gap: 4px;
    margin-top: 18px;
    padding: 14px 12px;
    text-align: center;
    color: var(--text-muted);
  }

  .empty-title {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
  }

  .empty-copy {
    max-width: 210px;
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }

  .download-group {
    display: grid;
    /* minmax(0, ...) so the auto track can't grow to the nowrap filename's min-content */
    grid-template-columns: minmax(0, 1fr);
    gap: 1px;
    margin-bottom: 8px;
  }

  .download-group-title {
    padding: 8px 4px 4px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
  }
</style>
