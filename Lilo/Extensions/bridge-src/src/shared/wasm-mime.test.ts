import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { installWasmMimeCompat } from './wasm-mime.ts';

// The smallest valid module: magic number and version, no sections.
const emptyModule = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
const location = { protocol: 'chrome-extension:', host: 'abc' };

function wasmResponse(url: string, contentType: string, status = 200): Response {
  const response = new Response(status === 200 ? emptyModule : null, { status, headers: { 'Content-Type': contentType } });
  Object.defineProperty(response, 'url', { value: url });
  return response;
}

describe('installWasmMimeCompat', () => {
  let scope: { WebAssembly: typeof WebAssembly; location: typeof location };

  beforeEach(() => {
    scope = { WebAssembly: { ...WebAssembly } as typeof WebAssembly, location };
    installWasmMimeCompat(scope);
  });

  it('stream-compiles a packaged module served without the wasm MIME type', async () => {
    const result = await scope.WebAssembly.instantiateStreaming(
      wasmResponse('chrome-extension://abc/assets/a.wasm', 'application/octet-stream'));
    assert.ok(result.module instanceof WebAssembly.Module);

    const module = await scope.WebAssembly.compileStreaming(
      Promise.resolve(wasmResponse('chrome-extension://abc/b.wasm', '')));
    assert.ok(module instanceof WebAssembly.Module);
  });

  it('leaves remote and failed responses to the native check', async () => {
    await assert.rejects(scope.WebAssembly.instantiateStreaming(
      wasmResponse('https://cdn.example/a.wasm', 'application/octet-stream')), TypeError);
    await assert.rejects(scope.WebAssembly.instantiateStreaming(
      wasmResponse('chrome-extension://abc/missing.wasm', 'text/plain', 404)), TypeError);
  });
});
