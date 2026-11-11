<!-- A download's visual: Quick Look's thumbnail of the finished file, else its type's Finder icon. -->
<script lang="ts">
  import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import { canOpen, fileIconURL, previewURL } from "./downloadsPanelModel";

  let { download, size }: { download: BridgeDownloadSnapshot; size: number } = $props();

  let failedId = $state<number | null>(null);
  const preview = $derived(canOpen(download) && failedId !== download.id);
</script>

<img
  class:preview
  src={preview ? previewURL(download) : fileIconURL(download)}
  alt=""
  width={size}
  height={size}
  draggable="false"
  onerror={() => {
    if (preview) failedId = download.id;
  }}
/>

<style>
  img {
    flex: none;
    object-fit: contain;
    pointer-events: none;
  }

  .preview {
    border-radius: var(--radius-xs);
  }
</style>
