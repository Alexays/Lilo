import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe("a content script's world", () => {
  it("gives WebKit's events Chrome's hasListeners", async () => {
    const prototype = { addListener(_listener: unknown) {}, removeListener(_listener: unknown) {}, hasListener() { return false; } };
    const onMessage = Object.create(prototype);
    const onChanged = Object.create({ addListener(_listener: unknown) {}, removeListener(_listener: unknown) {} });
    // As WebKit's: each namespace and event is a getter on its object's prototype.
    const runtime = Object.create({ sendMessage() {}, connect() {}, get id() { return 'abc'; }, get onMessage() { return onMessage; } });
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
  });
});
