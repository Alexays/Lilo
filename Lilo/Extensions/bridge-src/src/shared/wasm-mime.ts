// WebKit serves packaged .wasm without application/wasm, which instantiateStreaming rejects, so the extension's own
// responses compile from their bytes (faster than WebKit's streaming compile for a local file). SW-safe.

type WasmScope = {
  WebAssembly?: typeof WebAssembly;
  location?: { protocol: string; host: string };
};

export function installWasmMimeCompat(scope: WasmScope): void {
  const wasm = scope.WebAssembly;
  if (!wasm?.instantiateStreaming || !scope.location) return;
  // Built from protocol and host because a custom-scheme origin may serialize as "null".
  const extensionBase = `${scope.location.protocol}//${scope.location.host}/`;
  const packaged = (response: Response) => response.ok && response.url.startsWith(extensionBase);

  const { instantiateStreaming, compileStreaming } = wasm;
  wasm.instantiateStreaming = async (source, imports) => {
    const response = await source;
    if (!packaged(response)) return instantiateStreaming.call(wasm, response, imports);
    return wasm.instantiate(await response.arrayBuffer(), imports);
  };
  if (compileStreaming) {
    wasm.compileStreaming = async (source) => {
      const response = await source;
      if (!packaged(response)) return compileStreaming.call(wasm, response);
      return wasm.compile(await response.arrayBuffer());
    };
  }
}
