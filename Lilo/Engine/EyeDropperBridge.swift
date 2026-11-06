import AppKit
import WebKit

/// The EyeDropper API, which WebKit does not implement, on top of the system color sampler: the same
/// loupe as the macOS color panel, picking anywhere on screen.
@MainActor
final class EyeDropperBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let messageHandlerName = "liloEyeDropper"

    /// Shows the sampler and hands back the picked color, or nil when the user cancels.
    var sample: () async -> NSColor? = {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { continuation.resume(returning: $0) }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.frameInfo.securityOrigin.isPotentiallyTrustworthy else {
            return (nil, "NotAllowedError: EyeDropper needs a secure context")
        }
        guard let color = await sample()?.usingColorSpace(.sRGB) else { return (nil, "AbortError: The user canceled the selection") }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return unsafe (String(format: "#%02x%02x%02x", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent)), nil)
    }

    /// `window.EyeDropper` for `PageWorld`, in secure contexts.
    static let pageModule = #"""
    function () {
      if (!window.isSecureContext || 'EyeDropper' in window) return;
      // Promise.prototype.finally would look up the page's then.
      const then = NativePromise.prototype.then;
      let open = false;
      const instances = new WeakSet(), { add, has } = WeakSet.prototype;
      // A function, not a class: called without `new`, it throws WebKit's message, not JSC's.
      function EyeDropper() {
        if (!new.target) throw new NativeTypeError("Constructor requires 'new' operator");
        apply(add, instances, [this]);
      }
      defineProperty(EyeDropper, 'prototype', { writable: false });
      lilo.methods(EyeDropper.prototype, {
        open(options) {
          if (!apply(has, instances, [this])) return NativePromise.reject(new NativeTypeError('Can only call EyeDropper.open on instances of EyeDropper'));
          if (open) return NativePromise.reject(new DOMException('An eye dropper is already open.', 'InvalidStateError'));
          const signal = options && options.signal;
          if (signal && signal.aborted) return NativePromise.reject(signal.reason || new DOMException('Aborted', 'AbortError'));
          open = true;
          return apply(then, lilo.post('liloEyeDropper', {}), [sRGBHex => { open = false; return { sRGBHex }; }, error => {
            open = false;
            const text = String(error && error.message || error), match = /^(\w+): (.*)$/.exec(text);
            throw new DOMException(match ? match[2] : text, match ? match[1] : 'AbortError');
          }]);
        },
      });
      lilo.global('EyeDropper', lilo.nativeClass(EyeDropper));
    }
    """#
}
