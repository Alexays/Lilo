// Augments chrome.topSites with a gap-bridged read of the most-visited pages, backed by Lilo's
// history ranking (visitCount). Read-only: Chrome exposes only get().
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';

export const topSitesAugmentation = {
  get(callback?: (sites: Array<{ url: string; title: string }>) => void) {
    return callbackify(
      () => gapCall<Array<{ url: string; title: string }>>('topSites', 'get', {}),
      callback
    );
  },
};
