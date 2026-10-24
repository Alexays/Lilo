<script lang="ts">
  import type { Snippet } from "svelte";

  interface Props {
    tone?: "neutral" | "success" | "danger" | "accent";
    children?: Snippet;
  }

  let { tone = "neutral", children }: Props = $props();
</script>

<span class="ui-badge" class:success={tone === "success"} class:danger={tone === "danger"} class:accent={tone === "accent"}>
  {@render children?.()}
</span>

<style>
  .ui-badge {
    display: inline-flex;
    align-items: center;
    min-height: 18px;
    padding: var(--space-2) var(--space-8);
    border-radius: var(--radius-chip);
    background: color-mix(in srgb, var(--text-primary) 6%, transparent);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    line-height: 1;
    white-space: nowrap;
  }

  .ui-badge.success {
    background: color-mix(in srgb, var(--success) 14%, transparent);
    color: var(--success-text);
  }

  .ui-badge.danger {
    background: color-mix(in srgb, var(--danger-deep) 14%, transparent);
    color: color-mix(in srgb, var(--danger-deep) 84%, var(--text-primary));
  }

  .ui-badge.accent {
    background: var(--accent-tint-12);
    color: color-mix(in srgb, var(--accent) 78%, var(--text-primary));
  }
</style>
