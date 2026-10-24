// WebKit runs the pending promise callbacks while importScripts loads a script the worker had not loaded yet, Chrome
// once the worker's top-level code is done (WEBKIT-GAPS.md, gap 14). An empty script runs nothing either way, so its
// import is skipped and runs none: Tampermonkey imports an empty /test.js between its startup flag and its listeners.
// SW-safe: no window/document/webkit.

type ImportScope = {
  importScripts?: (...urls: string[]) => void;
  location: { href: string };
};

/** `emptyPaths` are the extension's empty scripts, root-relative ("/test.js"), as the preparer found them. */
export function skipEmptyImports(scope: ImportScope, emptyPaths: readonly string[]): void {
  const importScripts = scope.importScripts;
  if (typeof importScripts !== 'function' || !emptyPaths.length) return;
  const empty = new Set(emptyPaths);
  const isEmpty = (url: unknown) => {
    try {
      const base = new URL(scope.location.href);
      const resolved = new URL(String(url), base);
      return resolved.protocol === base.protocol && resolved.host === base.host && empty.has(decodeURIComponent(resolved.pathname));
    } catch {
      // An invalid URL is the native call's to reject.
      return false;
    }
  };
  scope.importScripts = (...urls: string[]) => {
    const loaded = urls.filter((url) => !isEmpty(url));
    if (loaded.length || !urls.length) importScripts.apply(scope, loaded);
  };
}
