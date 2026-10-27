import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe("a content script's world", () => {
  it("gives WebKit's events Chrome's hasListeners", async () => {
    const prototype = { addListener(_listener: unknown) {}, removeListener(_listener: unknown) {}, hasListener() { return false; } };
    const onMessage = Object.create(prototype);
    const onChanged = Object.create({ addListener(_listener: unknown) {}, removeListener(_listener: unknown) {} });
    (globalThis as any).chrome = {
      runtime: Object.assign(Object.create({ sendMessage() {}, connect() {} }), { id: 'abc', onMessage }),
      storage: { onChanged },
    };
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
