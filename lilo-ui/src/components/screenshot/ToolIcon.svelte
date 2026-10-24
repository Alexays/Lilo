<script lang="ts">
  // One icon per drawing tool of the capture editor.
  let { kind, size = 16 }: { kind: string; size?: number } = $props();
</script>

<svg
  width={size} height={size} viewBox="0 0 16 16" fill="none"
  stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"
  aria-hidden="true"
>
  {#if kind === "select"}
    <path d="M4 2.5 12.5 7.1 8.7 8.2 7.1 12z" />
  {:else if kind === "hand"}
    <g transform="scale(0.889)"><path d="M6 9V4.5a1 1 0 0 1 2 0V8M8 8V3.5a1 1 0 0 1 2 0V8M10 8V4.5a1 1 0 0 1 2 0V10M12 7a1 1 0 0 1 2 0v4a5 5 0 0 1-5 5H8.5a4 4 0 0 1-3.2-1.6L3 11.3a1 1 0 0 1 1.5-1.3L6 11.5" /></g>
  {:else if kind === "arrow"}
    <path d="M3.5 12.5 12 4" />
    <path d="M12 4H8M12 4V8" />
  {:else if kind === "rect"}
    <rect x="3" y="4" width="10" height="8" rx="1.5" />
  {:else if kind === "ellipse"}
    <ellipse cx="8" cy="8" rx="5.5" ry="4.5" />
  {:else if kind === "diamond"}
    <path d="M8 2.5 13.5 8 8 13.5 2.5 8z" />
  {:else if kind === "text"}
    <path d="M4 4H12M8 4V13" />
  {:else if kind === "draw" || kind === "pen"}
    <path d="M11 2.5 13.5 5 6 12.5 3 13l0.5-3L11 2.5Z" />
    <path d="M9.5 4 12 6.5" />
  {:else if kind === "note"}
    <g transform="scale(0.889)"><path d="M3 3h12v8l-4 4H3zM15 11h-4v4M6 7h6M6 9.5h3" /></g>
  {:else if kind === "link"}
    <g transform="scale(0.889)"><path d="M7.5 10.5l3-3M8.5 5.5l1-1a3 3 0 0 1 4.2 4.2l-1 1M9.5 12.5l-1 1a3 3 0 0 1-4.2-4.2l1-1" /></g>
  {:else if kind === "capture"}
    <g transform="scale(0.889)"><path d="M2.5 6a1.5 1.5 0 0 1 1.5-1.5h1.8L7 3h4l1.2 1.5H14A1.5 1.5 0 0 1 15.5 6v7A1.5 1.5 0 0 1 14 14.5H4A1.5 1.5 0 0 1 2.5 13z" /><circle cx="9" cy="9.3" r="2.6" /></g>
  {:else if kind === "highlight"}
    <rect x="3" y="4.5" width="10" height="4.5" rx="1" />
    <path d="M3 12.5H13" />
  {:else if kind === "blur"}
    <path d="M8 2.2C8 2.2 4 7 4 10a4 4 0 0 0 8 0c0-3-4-7.8-4-7.8Z" />
  {:else if kind === "crop"}
    <path d="M5 2V11H14" />
    <path d="M2 5H11V14" />
  {:else if kind === "badge"}
    <circle cx="8" cy="8" r="5.5" />
    <text x="8" y="8" text-anchor="middle" dominant-baseline="central" font-size="7" font-weight="700" fill="currentColor" stroke="none">1</text>
  {/if}
</svg>
