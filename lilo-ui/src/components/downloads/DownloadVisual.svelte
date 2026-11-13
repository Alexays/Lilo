<!-- A download's visual: Quick Look's thumbnail of the finished file, else its type's Finder icon. -->
<script lang="ts">
  import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import { canOpen, fileIconURL, previewURL } from "./downloadsPanelModel";

  let { download, size }: { download: BridgeDownloadSnapshot; size: number } = $props();

  let failedId = $state<number | null>(null);
  const preview = $derived(canOpen(download) && failedId !== download.id);
</script>

<!-- Styled inline: a stylesheet of its own would add a file to the first frame's preload map. -->
<img
  src={preview ? previewURL(download) : fileIconURL(download)}
  alt=""
  width={size}
  height={size}
  draggable="false"
  style:flex="none"
  style:object-fit="contain"
  style:pointer-events="none"
  style:border-radius={preview ? "var(--radius-xs)" : undefined}
  onerror={() => {
    if (preview) failedId = download.id;
  }}
/>
