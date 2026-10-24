<!-- A panel's last action result: dismissed by its close button or after a few seconds. -->
<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { announce } from "../../lib/announce";

  let { status = $bindable() }: { status: { level: string; message: string } | null } = $props();

  $effect(() => {
    if (!status) return;
    announce(status.message);
    const timer = setTimeout(() => (status = null), 4000);
    return () => clearTimeout(timer);
  });
</script>

{#if status}
  <div class="status-banner" class:status-error={status.level === "error"}>
    <span>{status.message}</span>
    <button class="status-close" type="button" aria-label={t("common.close")} onclick={() => (status = null)}>
      <svg width="10" height="10" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2 2l8 8M10 2l-8 8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
    </button>
  </div>
{/if}

<style>
  .status-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    border-radius: var(--radius-md);
    background: var(--sidebar-active);
    padding: 8px 10px;
    font-size: var(--font-size-sm);
  }

  .status-banner.status-error {
    color: var(--sidebar-danger);
    background: color-mix(in srgb, var(--sidebar-danger) 12%, transparent);
  }

  .status-close {
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: none;
    color: inherit;
    cursor: pointer;
  }
</style>
