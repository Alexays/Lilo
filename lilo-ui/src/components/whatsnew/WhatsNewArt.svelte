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
  {:else if kind === "history"}
    <rect width="128" height="90" rx="10" fill="var(--accent-tint-14)" />
    <rect x="14" y="12" width="100" height="66" rx="7" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <rect x="22" y="19" width="22" height="4" rx="2" fill="var(--text-secondary)" /><rect x="48" y="19" width="26" height="4" rx="2" fill="var(--separator)" />
    <rect x="20" y="28" width="88" height="14" rx="4" fill="var(--accent-tint-14)" />
    <circle cx="28" cy="35" r="3.5" fill="var(--accent)" /><rect x="35" y="33" width="26" height="4" rx="2" fill="var(--text-secondary)" />
    <rect x="80" y="31.5" width="16" height="7" rx="3.5" fill="var(--accent)" /><path d="m101 33 2 2-2 2" fill="none" stroke="var(--text-secondary)" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" />
    <g fill="var(--separator)"><rect x="35" y="49" width="40" height="4" rx="2" /><rect x="35" y="61" width="32" height="4" rx="2" /></g>
    <circle cx="28" cy="51" r="3.5" fill="var(--success)" /><circle cx="28" cy="63" r="3.5" fill="var(--warning)" />
    <g fill="var(--text-secondary)"><rect x="92" y="49" width="12" height="4" rx="2" opacity="0.6" /><rect x="92" y="61" width="12" height="4" rx="2" opacity="0.6" /></g>
  {:else if kind === "pip"}
    <rect width="128" height="90" rx="10" fill="color-mix(in srgb, var(--success) 10%, var(--bg-elevated))" />
    <rect x="12" y="12" width="84" height="58" rx="6" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <g stroke="var(--text-secondary)" stroke-width="1.3" stroke-linecap="round" opacity="0.6"><path d="M20 24h40m-40 8h56m-56 8h32" /></g>
    <rect x="62" y="40" width="54" height="40" rx="7" fill="var(--terminal-tile-bg)" stroke="var(--separator)" />
    <circle cx="89" cy="55" r="7" fill="var(--success)" />
    <g fill="none" stroke="var(--terminal-tile-text)" stroke-width="1.2" stroke-linecap="round" opacity="0.85"><rect x="73" y="67" width="4" height="7" rx="2" /><path d="M85 68h6v6h-6zm6 2 3-1.5v5l-3-1.5" /></g>
    <rect x="99" y="67.5" width="10" height="6" rx="3" fill="var(--danger-deep)" />
  {:else if kind === "languages"}
    <rect width="128" height="90" rx="10" fill="var(--accent-tint-14)" />
    <rect x="14" y="16" width="50" height="26" rx="10" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <rect x="64" y="34" width="50" height="26" rx="10" fill="var(--accent)" />
    <rect x="26" y="52" width="44" height="24" rx="10" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <g font-family="inherit" font-size="11" text-anchor="middle"><text x="39" y="33" fill="var(--text-primary)">Hallo</text><text x="89" y="51" fill="var(--accent-text)">Ciao</text><text x="48" y="68" fill="var(--text-primary)">こんにちは</text></g>
  {:else if kind === "fresh"}
    <rect width="128" height="90" rx="10" fill="var(--accent-tint-14)" />
    <rect x="12" y="12" width="104" height="66" rx="7" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <rect x="18" y="18" width="28" height="54" rx="4" fill="var(--accent-tint-14)" />
    <g fill="var(--bg-elevated)" stroke="var(--separator)"><rect x="21" y="22" width="10" height="10" rx="3" /><rect x="33" y="22" width="10" height="10" rx="3" /></g>
    <g fill="var(--separator)"><rect x="22" y="38" width="20" height="4" rx="2" /><rect x="22" y="46" width="16" height="4" rx="2" /></g>
    <circle cx="80" cy="45" r="13" fill="var(--accent-tint-14)" />
    <path d="m73 45 5 5 9-10" fill="none" stroke="var(--accent)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
  {:else if kind === "archive"}
    <rect width="128" height="90" rx="10" fill="color-mix(in srgb, var(--success) 10%, var(--bg-elevated))" />
    <rect x="20" y="12" width="88" height="66" rx="7" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <rect x="27" y="19" width="74" height="12" rx="4" fill="var(--separator)" opacity="0.5" />
    <path d="M33 25h6m-3-3v6" stroke="var(--text-secondary)" stroke-width="1.3" stroke-linecap="round" />
    <g fill="var(--text-secondary)" opacity="0.45"><circle cx="34" cy="43" r="3.5" /><rect x="41" y="41" width="34" height="4" rx="2" /><circle cx="34" cy="57" r="3.5" /><rect x="41" y="55" width="28" height="4" rx="2" /></g>
    <rect x="80" y="37" width="20" height="12" rx="6" fill="var(--success)" />
    <path d="M94 43h-8m3-3-3 3 3 3" fill="none" stroke="var(--bg-elevated)" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
  {:else if kind === "material"}
    <rect width="128" height="90" rx="10" fill="var(--accent-tint-14)" />
    <rect x="12" y="20" width="30" height="50" rx="6" fill="var(--accent)" />
    <rect x="49" y="20" width="30" height="50" rx="6" fill="color-mix(in srgb, var(--accent) 30%, var(--bg-elevated))" stroke="var(--bg-elevated)" stroke-width="1.5" />
    <path d="M53 25q8-3 16 0" fill="none" stroke="var(--bg-elevated)" stroke-width="1.5" stroke-linecap="round" />
    <rect x="86" y="20" width="30" height="50" rx="6" fill="color-mix(in srgb, var(--accent) 70%, var(--bg-elevated))" />
    <g fill="var(--text-secondary)" opacity="0.35"><circle cx="92" cy="28" r="0.9" /><circle cx="101" cy="33" r="0.9" /><circle cx="109" cy="27" r="0.9" /><circle cx="95" cy="42" r="0.9" /><circle cx="106" cy="46" r="0.9" /><circle cx="91" cy="55" r="0.9" /><circle cx="102" cy="58" r="0.9" /><circle cx="110" cy="63" r="0.9" /><circle cx="97" cy="65" r="0.9" /></g>
  {:else if kind === "colors"}
    <rect width="128" height="90" rx="10" fill="color-mix(in srgb, var(--warning) 12%, var(--bg-elevated))" />
    <rect x="12" y="14" width="104" height="62" rx="7" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <rect x="18" y="20" width="28" height="50" rx="4" fill="color-mix(in srgb, var(--danger) 30%, var(--bg-elevated))" />
    <rect x="52" y="20" width="58" height="10" rx="3" fill="var(--danger)" /><rect x="56" y="23" width="4" height="4" rx="1" fill="var(--bg-elevated)" />
    <g stroke="var(--separator)" stroke-width="3" stroke-linecap="round"><path d="M56 40h40m-40 8h48" /></g>
    <g fill="none" stroke="var(--text-secondary)" stroke-width="1.3" stroke-linecap="round"><circle cx="64" cy="62" r="3" /><path d="M64 56v1.5m0 9v1.5m-6-6h1.5m9 0h1.5" /><path d="M74 62h8m-2-2 2 2-2 2" /></g>
    <path d="M94 59a4 4 0 1 1-4.5 6a4 4 0 0 0 4.5-6z" fill="var(--text-secondary)" />
  {:else if kind === "seasons"}
    <rect width="128" height="90" rx="10" fill="color-mix(in srgb, var(--warning) 12%, var(--bg-elevated))" />
    <rect x="14" y="16" width="58" height="58" rx="14" fill="var(--bg-elevated)" stroke="var(--separator)" />
    <g fill="var(--accent)">
      <ellipse cx="37" cy="39" rx="6.5" ry="10" transform="rotate(-45 37 39)" opacity="0.45" />
      <ellipse cx="49" cy="39" rx="6.5" ry="10" transform="rotate(45 49 39)" opacity="0.65" />
      <ellipse cx="37" cy="51" rx="6.5" ry="10" transform="rotate(45 37 51)" opacity="0.8" />
      <ellipse cx="49" cy="51" rx="6.5" ry="10" transform="rotate(-45 49 51)" />
    </g>
    <path d="M43 16v22" stroke="var(--text-secondary)" stroke-width="1" />
    <g stroke="var(--text-primary)" stroke-width="1.2" stroke-linecap="round" fill="none"><path d="M40 41l-3-2m3 4h-3.5m3.5 2-3 2m9-6 3-2m-3 4h3.5m-3.5 2 3 2" /></g>
    <circle cx="43" cy="43" r="3" fill="var(--text-primary)" /><circle cx="43" cy="39.5" r="1.8" fill="var(--text-primary)" />
    <g fill="var(--bg-elevated)" stroke="var(--separator)"><rect x="84" y="12" width="26" height="20" rx="6" /><rect x="84" y="35" width="26" height="20" rx="6" /><rect x="84" y="58" width="26" height="20" rx="6" /></g>
    <path d="M97 27c-4-3-6-5-6-7.5a2.6 2.6 0 0 1 6-1.4a2.6 2.6 0 0 1 6 1.4c0 2.5-2 4.5-6 7.5z" fill="var(--danger)" />
    <path d="M97 39v12m-5.2-9 10.4 6m-10.4 0 10.4-6" stroke="var(--accent)" stroke-width="1.4" stroke-linecap="round" />
    <circle cx="97" cy="68" r="3.5" fill="var(--warning)" />
    <path d="M97 61.5v1.8m0 9.4v1.8m-6.5-6.5h1.8m9.4 0h1.8m-11.1-4.6 1.3 1.3m6.6 6.6 1.3 1.3m0-9.2-1.3 1.3m-6.6 6.6-1.3 1.3" stroke="var(--warning)" stroke-width="1.3" stroke-linecap="round" />
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
