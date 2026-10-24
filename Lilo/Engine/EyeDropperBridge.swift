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
        return (String(format: "#%02x%02x%02x", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent)), nil)
    }

    static let polyfillSource = """
(function(){
'use strict';
var handler=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.liloEyeDropper;
if(!handler||!window.isSecureContext||'EyeDropper' in window)return;
var open=false;
class EyeDropper{
open(options){
if(open)return Promise.reject(new DOMException('An eye dropper is already open.','InvalidStateError'));
var signal=options&&options.signal;
if(signal&&signal.aborted)return Promise.reject(signal.reason||new DOMException('Aborted','AbortError'));
open=true;
return handler.postMessage({}).then(function(hex){return {sRGBHex:hex};},function(e){
var text=String(e&&e.message||e),m=/^(\\w+): (.*)$/.exec(text);
throw new DOMException(m?m[2]:text,m?m[1]:'AbortError');
}).finally(function(){open=false;});
}
}
window.EyeDropper=EyeDropper;
})();
"""
}
