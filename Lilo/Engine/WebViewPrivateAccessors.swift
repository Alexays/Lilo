import Foundation
import WebKit

/// Calls into private WebKit SPI on a `WKWebView` or its `_inspector` (process pids/state, capture,
/// PiP, audio, Web Inspector), so the `unsafeBitCast` reflection lives in exactly one place.
@MainActor
struct WebViewPrivateAccessors {
    let object: NSObject
    init(_ object: NSObject) { self.object = object }

    /// Resolves a private WKWebView selector behind a `responds(to:)` guard, returning the
    /// `(selector, IMP)` pair the typed accessors below `unsafeBitCast` to their C signature.
    private func method(_ name: String) -> (Selector, IMP)? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return (selector, object.method(for: selector))
    }

    func bool(_ name: String) -> Bool? {
        guard let (selector, imp) = method(name) else { return nil }
        typealias BoolMethod = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(imp, to: BoolMethod.self)(object, selector)
    }

    func pid(_ name: String) -> Int? {
        guard let (selector, imp) = method(name) else { return nil }
        typealias PIDMethod = @convention(c) (NSObject, Selector) -> Int32
        let pid = unsafeBitCast(imp, to: PIDMethod.self)(object, selector)
        return pid > 0 ? Int(pid) : nil
    }

    func int(_ name: String) -> Int? {
        guard let (selector, imp) = method(name) else { return nil }
        typealias IntMethod = @convention(c) (NSObject, Selector) -> Int
        return unsafeBitCast(imp, to: IntMethod.self)(object, selector)
    }

    /// Reads a private URL-returning selector (e.g. `_committedURL`) as its absolute string.
    func urlString(_ name: String) -> String? {
        guard let (selector, imp) = method(name) else { return nil }
        typealias ObjectMethod = @convention(c) (NSObject, Selector) -> Unmanaged<AnyObject>?
        return (unsafeBitCast(imp, to: ObjectMethod.self)(object, selector)?.takeUnretainedValue() as? URL)?.absoluteString
    }

    /// Invokes a private one-argument `(unsigned)` setter (e.g. `_setPageMuted:`). No-ops if absent.
    func setUInt(_ name: String, _ value: UInt) {
        guard let (selector, imp) = method(name) else { return }
        typealias SetMethod = @convention(c) (NSObject, Selector, UInt) -> Void
        unsafeBitCast(imp, to: SetMethod.self)(object, selector, value)
    }

    /// `evaluateJavaScript(_:in:in:)` without the user gesture WebKit runs it under: a script Lilo runs
    /// on its own must not activate the page, which may then hold its own navigations behind a
    /// beforeunload panel, waiting synchronously for an answer.
    func evaluateWithoutUserGesture(_ source: String, in frame: WKFrameInfo? = nil, in world: WKContentWorld = .page,
                                    completion: (@MainActor @Sendable (Any?) -> Void)? = nil) {
        guard let (selector, imp) = method("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:") else {
            (object as? WKWebView)?.evaluateJavaScript(source, in: frame, in: world) { completion?(try? $0.get()) }
            return
        }
        typealias EvaluateMethod = @convention(c) (
            NSObject, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, Bool, @escaping @convention(block) (Any?, Error?) -> Void
        ) -> Void
        unsafeBitCast(imp, to: EvaluateMethod.self)(object, selector, source as NSString, nil, frame, world, false) { result, _ in
            MainActor.assumeIsolated { completion?(result) }
        }
    }

    /// Invokes a private selector taking a `void (^)(BOOL)` completion (e.g. `_suspendPage:`).
    /// Returns false, without calling `completion`, if the selector is unavailable on this OS.
    @discardableResult
    func invoke(_ name: String, completion: @escaping (Bool) -> Void) -> Bool {
        guard let (selector, imp) = method(name) else { return false }
        typealias CompletionMethod = @convention(c) (NSObject, Selector, @escaping @convention(block) (Bool) -> Void) -> Void
        unsafeBitCast(imp, to: CompletionMethod.self)(object, selector, completion)
        return true
    }
}
