import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe("a content script's world", () => {
  it("gives WebKit's events Chrome's hasListeners and the extension its own manifest", async () => {
    const prototype = { addListener(_listener: unknown) {}, removeListener(_listener: unknown) {}, hasListener() { return false; } };
    const onMessage = Object.create(prototype);
    const onChanged = Object.create({ addListener(_listener: unknown) {}, removeListener(_listener: unknown) {} });
    // As WebKit's: each namespace and event is a getter on its object's prototype.
    const manifest = { background: { service_worker: '_lilo/sw.js', lilo_service_worker: 'sw.js' }, content_scripts: [{ matches: ['<all_urls>'], js: ['_lilo/lilo-content-compat.js', 'a.js'] }] };
    const runtime = Object.create({
      sendMessage() {}, connect() {}, getManifest() { return structuredClone(manifest); },
      get id() { return 'abc'; }, get onMessage() { return onMessage; },
    });
    const storage = Object.create({ get onChanged() { return onChanged; } });
    (globalThis as any).chrome = Object.create({ get runtime() { return runtime; }, get storage() { return storage; } });
    await import('./content-compat-entry.ts');
    const listener = () => {};
    assert.equal(onMessage.hasListeners(), false);
    onMessage.addListener(listener);
    assert.equal(onMessage.hasListeners(), true);
    onMessage.removeListener(listener);
    assert.equal(onMessage.hasListeners(), false);
    onChanged.addListener(listener);
    assert.equal(onChanged.hasListeners(), true);
    const { getManifest } = (globalThis as any).chrome.runtime;
    assert.deepEqual(getManifest().content_scripts[0].js, ['a.js'], "the manifest shows the extension's own content scripts");
    assert.equal(getManifest().background.service_worker, 'sw.js');
  });
});
