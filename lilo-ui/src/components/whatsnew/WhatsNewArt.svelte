<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { ReleaseIllustration } from "./releaseNotes";
  let { kind }: { kind: ReleaseIllustration } = $props();
</script>

<svg class="release-art" viewBox="0 0 128 90" aria-hidden="true">
  {#if kind === "unread"}
    <rect width="128" height="90" rx="10" fill="var(--accent-tint-14)" />
    <rect x="12" y="19" width="104" height="24" rx="5" fill="var(--bg-elevated)" />
    <rect x="12" y="48" width="104" height="24" rx="5" fill="var(--bg-elevated)" />
    <g fill="none" stroke="var(--text-secondary)" stroke-width="1.3" stroke-linejoin="round">
      <rect x="20" y="26" width="12" height="9" rx="1" /><path d="m20 27 6 4 6-4" />
      <path d="M21 55h10v8h-6l-3 3v-3h-1z" />
    </g>
    <g fill="var(--text-secondary)" font-size="9" font-family="inherit"><text x="39" y="34">{t("whatsNew.art.inbox")}</text><text x="39" y="63">{t("whatsNew.art.chat")}</text></g>
    <rect x="96" y="24" width="14" height="14" rx="7" fill="var(--accent)" /><text x="103" y="34" text-anchor="middle" fill="var(--accent-text)" font-size="9">3</text>
    <circle cx="103" cy="60" r="3" fill="var(--accent)" />
  {:else if kind === "share"}
    <rect width="128" height="90" rx="10" fill="var(--accent-tint-14)" />
    <rect x="12" y="14" width="74" height="62" rx="6" fill="var(--bg-elevated)" />
    <rect x="18" y="20" width="20" height="8" rx="3" fill="var(--separator)" /><rect x="41" y="20" width="20" height="8" rx="3" fill="var(--accent)" /><rect x="64" y="20" width="16" height="8" rx="3" fill="var(--separator)" />
    <rect x="18" y="34" width="62" height="36" rx="4" fill="none" stroke="var(--accent)" stroke-width="1.5" />
    <g stroke="var(--text-secondary)" stroke-width="1.3" stroke-linecap="round"><path d="M24 43h34m-34 7h48m-48 7h28" /></g>
    <rect x="80" y="44" width="38" height="34" rx="6" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <circle cx="99" cy="56" r="6" fill="var(--success)" />
    <g fill="none" stroke="var(--text-secondary)" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M88 70h6m-2-2 2 2-2 2" /><path d="M104 68v4m3-6v8m3-5v2" /></g>
  {:else if kind === "address"}
    <rect width="128" height="90" rx="10" fill="color-mix(in srgb, var(--success) 10%, var(--bg-elevated))" />
    <rect x="16" y="12" width="96" height="66" rx="6" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <rect x="24" y="18" width="80" height="7" rx="3.5" fill="none" stroke="var(--text-secondary)" stroke-width="1" stroke-dasharray="3 2" opacity="0.6" />
    <rect x="22" y="29" width="84" height="43" rx="4" fill="color-mix(in srgb, var(--success) 18%, var(--bg-elevated))" />
    <g stroke="var(--text-secondary)" stroke-width="1.3" stroke-linecap="round"><path d="M30 39h44m-44 8h58m-58 8h36" /></g>
    <g fill="none" stroke="var(--success)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M64 61v8m-3-5 3-3 3 3" /></g>
  {:else}
    <rect width="128" height="90" rx="10" fill="color-mix(in srgb, var(--success) 10%, var(--bg-elevated))" />
    <rect x="24" y="18" width="36" height="39" rx="6" fill="color-mix(in srgb, var(--success) 20%, var(--bg-elevated))" />
    <rect x="67" y="18" width="36" height="39" rx="6" fill="var(--accent-tint-14)" />
    <circle cx="42" cy="31" r="6" fill="var(--success)" /><path d="M30 54v-5a12 12 0 0 1 24 0v5z" fill="var(--success)" />
    <circle cx="85" cy="31" r="6" fill="var(--accent-ink)" /><path d="M73 54v-5a12 12 0 0 1 24 0v5z" fill="var(--accent-ink)" />
    <g stroke="var(--text-secondary)" stroke-width="1.3" fill="none" stroke-linecap="round"><rect x="34" y="66" width="5" height="8" rx="2.5" /><path d="M32 70a4.5 4.5 0 0 0 9 0m-4.5 5v3m20-11h8v8h-8zM65 69l4-2v8l-4-2" /></g>
    <rect x="83" y="65" width="17" height="13" rx="6.5" fill="var(--danger-deep)" /><path d="M88 72q4-4 8 0" fill="none" stroke="var(--on-color)" stroke-width="1.5" stroke-linecap="round" />
  {/if}
</svg>

<style>
  .release-art { display: block; width: 100%; border: 1px solid var(--separator); border-radius: var(--radius-md); }
</style>
