<script lang="ts">
  import type { Snippet } from "svelte";
  import { reportChromeError } from "../../lib/chromeErrors";

  let { children }: { children: Snippet } = $props();

  // Without a boundary, a region that throws stays frozen on its last frame for good. This one renders
  // again later, when its data has usually moved on; the wait doubles while it keeps failing.
  const FIRST_RETRY_MS = 1000;
  const LAST_RETRY_MS = 60_000;
  let delay = FIRST_RETRY_MS;
  let failing = false;
  let timer: ReturnType<typeof setTimeout> | undefined;

  function handleError(error: unknown, reset: () => void): void {
    failing = true;
    reportChromeError(error);
    clearTimeout(timer);
    timer = setTimeout(() => {
      failing = false;
      reset();
      if (!failing) delay = FIRST_RETRY_MS;
    }, delay);
    delay = Math.min(delay * 2, LAST_RETRY_MS);
  }

  $effect(() => () => clearTimeout(timer));
</script>

<svelte:boundary onerror={handleError}>{@render children()}</svelte:boundary>
