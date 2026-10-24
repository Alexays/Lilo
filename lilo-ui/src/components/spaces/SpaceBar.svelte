<script lang="ts">
  import { getSpaceById } from "../../stores/spaces.svelte";
  import { openEditor } from "../../stores/panels.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { t } from "../../lib/i18n/state.svelte";

  let {
    spaceId,
    interactive,
  }: { spaceId: string; interactive: boolean } = $props();

  const space = $derived(getSpaceById(spaceId));

  function handleEdit() {
    if (!interactive) return;
    openEditor(space?.id);
  }
</script>

<div class="space-label">
  <button
    class="space-name-btn"
    class:interactive
    class:is-private={space?.isPrivate}
    onclick={handleEdit}
    use:tooltip={t("spaceBar.editSpace")}
  >
    <span class="space-icon-stack">
      <span class="space-icon" data-onboarding-anchor="space-icon">{space?.icon || "🌐"}</span>
      {#if space?.isPrivate}
        <span
          class="space-private-badge"
          role="img"
          aria-label={t("spaceBar.privateSpace")}
          use:tooltip={t("spaceBar.privateSpace")}
        >
          <svg
            width="9"
            height="9"
            viewBox="0 0 16 16"
            fill="none"
            aria-hidden="true"
          >
            <path
              d="M5.25 6V4.75a2.75 2.75 0 1 1 5.5 0V6M4.5 6h7A1.5 1.5 0 0 1 13 7.5v4A1.5 1.5 0 0 1 11.5 13h-7A1.5 1.5 0 0 1 3 11.5v-4A1.5 1.5 0 0 1 4.5 6Z"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </span>
      {/if}
    </span>
    <span class="space-name">{space?.name || t("spaceBar.defaultSpaceName")}</span>
    <svg
      class="space-edit-icon"
      width="10"
      height="10"
      viewBox="0 0 16 16"
      fill="none"
    >
      <path
        d="M11.5 1.5l3 3L5 14H2v-3L11.5 1.5z"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  </button>
</div>

<style>
  /* Room for the keep-awake pill the sidebar lays over this row. */
  .space-label {
    padding: 4px calc(var(--sidebar-right-pad, 10px) + var(--keep-awake-reserve, 0px)) 4px 10px;
    flex-shrink: 0;
  }

  .space-name-btn {
    display: flex;
    align-items: center;
    gap: 8px;
    border: none;
    background: none;
    padding: 6px;
    border-radius: var(--radius-md);
    cursor: default;
    color: var(--text-muted);
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
    font-family: inherit;
    width: 100%;
    position: relative;
  }

  .space-name-btn.is-private {
    color: color-mix(in srgb, var(--text-primary) 88%, white 12%);
  }

  .space-name-btn.interactive {
    cursor: pointer;
  }

  .space-name-btn.interactive:hover {
    background: var(--bg-hover);
    color: var(--text-secondary);
  }

  .space-name-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .space-name-btn.is-private.interactive:hover {
    color: color-mix(in srgb, var(--text-primary) 94%, white 6%);
  }

  /* Favicon-sized, on the favicon column, so the name lines up with the tab titles. */
  .space-icon-stack {
    position: relative;
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    color: var(--text-primary);
  }

  .space-icon {
    font-size: var(--font-size-md);
    line-height: 1;
  }

  .space-private-badge {
    position: absolute;
    left: -5px;
    top: -4px;
    width: 13px;
    height: 13px;
    border-radius: var(--radius-chip);
    display: flex;
    align-items: center;
    justify-content: center;
    background: color-mix(in srgb, var(--on-pastel) 88%, black 12%);
    color: color-mix(in srgb, white 92%, var(--accent) 8%);
    border: 1px solid color-mix(in srgb, white 20%, transparent);
    box-shadow: var(--shadow-sm);
  }

  .space-name {
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    text-align: left;
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .space-edit-icon {
    opacity: 0;
    transition: opacity var(--transition-fast);
    color: var(--text-muted);
  }

  .space-name-btn.interactive:hover .space-edit-icon {
    opacity: 1;
  }
</style>
