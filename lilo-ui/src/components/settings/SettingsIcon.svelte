<script lang="ts">
  import type { SettingsGlyph } from "./settingsPanelModel";

  interface Props {
    name: SettingsGlyph;
  }

  let { name }: Props = $props();
</script>

<svg class="settings-icon-svg" viewBox="0 0 20 20" aria-hidden="true">
  {#if name === "general"}
    <path d="M4 6.5h7.2" />
    <path d="M14.6 6.5H16" />
    <path d="M4 13.5h1.4" />
    <path d="M8.8 13.5H16" />
    <circle cx="12.8" cy="6.5" r="1.6" />
    <circle cx="7.2" cy="13.5" r="1.6" />
  {:else if name === "appearance"}
    <circle cx="10" cy="10" r="3.1" />
    <path d="M10 2.9v1.4" />
    <path d="M10 15.7v1.4" />
    <path d="M2.9 10h1.4" />
    <path d="M15.7 10h1.4" />
    <path d="m5 5 1 1" />
    <path d="m14 14 1 1" />
    <path d="m15 5-1 1" />
    <path d="m6 14-1 1" />
  {:else if name === "terminal"}
    <rect x="2.8" y="3.8" width="14.4" height="12.4" rx="2.6" />
    <path d="m6.2 8 2.4 2-2.4 2" />
    <path d="M10.4 12.4h3.4" />
  {:else if name === "tabs"}
    <rect x="3.4" y="6.2" width="10.4" height="10.4" rx="2.6" />
    <path d="M6.4 3.4h7.6a2.6 2.6 0 0 1 2.6 2.6v7.6" />
  {:else if name === "media"}
    <circle cx="10" cy="10" r="7" />
    <path d="M8.6 7.4v5.2l4.1-2.6Z" />
  {:else if name === "privacy"}
    <path d="M10 2.8 4.8 5v4.4c0 3.2 2 5.8 5.2 7.8 3.2-2 5.2-4.6 5.2-7.8V5L10 2.8Z" />
    <path d="m7.8 10 1.5 1.5 3-3.2" />
  {:else if name === "extensions"}
    <path d="M4.4 7.4h2.8a1.9 1.9 0 1 1 3.8 0h2.8v2.8a1.9 1.9 0 1 1 0 3.8v2.6H4.4V7.4Z" />
  {:else if name === "agents"}
    <path d="m5 3.6 9.4 5.2-4 1.2 2.6 4.6-1.8 1-2.6-4.6-3 2.8Z" />
  {:else if name === "advanced"}
    <path d="M8 3.4h4" />
    <path d="M8.8 3.4v4.4l-4.1 6.8c-.6 1 .1 2.1 1.2 2.1h8.2c1.1 0 1.8-1.1 1.2-2.1l-4.1-6.8V3.4" />
    <path d="M6.6 12.4h6.8" />
  {:else if name === "arrowOutOfBox"}
    <path d="M9 4.4H6.4a2.4 2.4 0 0 0-2.4 2.4v6.8a2.4 2.4 0 0 0 2.4 2.4h6.8a2.4 2.4 0 0 0 2.4-2.4V11" />
    <path d="M11.8 3.6h4.6v4.6" />
    <path d="m16.4 3.6-6.8 6.8" />
  {:else if name === "folder"}
    <path d="M3 6.4a2 2 0 0 1 2-2h2.8l1.8 1.8H15a2 2 0 0 1 2 2v6.4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
    <path d="M3 8.6h14" />
  {:else if name === "play"}
    <path d="M6 4.8v10.4a.9.9 0 0 0 1.4.8l8-5.2a.9.9 0 0 0 0-1.6l-8-5.2a.9.9 0 0 0-1.4.8Z" />
  {:else if name === "halfCircle"}
    <circle cx="10" cy="10" r="6.8" />
    <path class="filled" d="M10 3.2a6.8 6.8 0 0 0 0 13.6Z" />
  {:else if name === "page"}
    <path d="M5.2 4.8a2 2 0 0 1 2-2h3.8l3.8 3.8v8.6a2 2 0 0 1-2 2H7.2a2 2 0 0 1-2-2Z" />
    <path d="M10.8 3v3.8h3.8" />
    <path d="M8 10.6h4" />
    <path d="M8 13.4h4" />
  {:else if name === "stack"}
    <rect x="3.4" y="8" width="13.2" height="8.6" rx="2.2" />
    <path d="M5.4 5.4h9.2" />
    <path d="M7.4 2.8h5.2" />
  {:else if name === "clock"}
    <circle cx="10" cy="10" r="7" />
    <path d="M10 6v4l2.6 1.8" />
  {:else if name === "grid"}
    <rect x="3.4" y="3.4" width="5.6" height="5.6" rx="1.6" />
    <rect x="11" y="3.4" width="5.6" height="5.6" rx="1.6" />
    <rect x="3.4" y="11" width="5.6" height="5.6" rx="1.6" />
    <rect x="11" y="11" width="5.6" height="5.6" rx="1.6" />
  {:else if name === "globe"}
    <circle cx="10" cy="10" r="7" />
    <ellipse cx="10" cy="10" rx="3" ry="7" />
    <path d="M3 10h14" />
  {/if}
</svg>

<style>
  .settings-icon-svg {
    width: 16px;
    height: 16px;
    display: block;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.6;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .filled {
    fill: currentColor;
  }
</style>
