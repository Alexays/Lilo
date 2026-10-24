// Injected into regular tabs, which never get ChromeAPIAugmentation.js; the store shim self-guards on the store
// hostname so chrome.* does not leak onto every other site.
import { installWebstorePrivate } from './augmentation/webstorePrivate.ts';

installWebstorePrivate(globalThis as any);
