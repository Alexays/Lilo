import AppKit
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

    /// Whether the page has yet to finish handling a mouse event sent to it: WebKit runs the block at once when none is in
    /// flight. Nil when WebKit dropped the selector.
    func isProcessingMouseEvents() -> Bool? {
        guard let (selector, imp) = method("_doAfterProcessingAllPendingMouseEvents:") else { return nil }
        typealias BlockMethod = @convention(c) (NSObject, Selector, @escaping @convention(block) () -> Void) -> Void
        var processing = true
        unsafeBitCast(imp, to: BlockMethod.self)(object, selector) { processing = false }
        return processing
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

    /// `callAsyncJavaScript(_:arguments:in:in:)` without the user gesture WebKit runs it under, for the same reason.
    func callAsyncWithoutUserGesture(_ body: String, arguments: [String: Any], in world: WKContentWorld = .page,
                                     completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        guard let (selector, imp) = method("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:") else {
            (object as? WKWebView)?.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                if case .failure(let error) = result { completion(error) } else { completion(nil) }
            }
            return
        }
        typealias CallMethod = @convention(c) (
            NSObject, Selector, NSString, NSDictionary, WKFrameInfo?, WKContentWorld, Bool, @escaping @convention(block) (Any?, Error?) -> Void
        ) -> Void
        unsafeBitCast(imp, to: CallMethod.self)(object, selector, body as NSString, arguments as NSDictionary, nil, world, false) { _, error in
            MainActor.assumeIsolated { completion(error) }
        }
    }

    /// The main frame's response body as loaded, from `_getMainResourceDataWithCompletionHandler:`.
    /// Returns false, without calling `completion`, if the selector is unavailable on this OS.
    @discardableResult
    func mainResourceData(completion: @escaping @MainActor (Data?) -> Void) -> Bool {
        guard let (selector, imp) = method("_getMainResourceDataWithCompletionHandler:") else { return false }
        typealias DataMethod = @convention(c) (NSObject, Selector, @escaping @convention(block) (NSData?, NSError?) -> Void) -> Void
        unsafeBitCast(imp, to: DataMethod.self)(object, selector) { data, _ in
            MainActor.assumeIsolated { completion(data as Data?) }
        }
        return true
    }

    /// The focused frame's selected text, copied to the find pasteboard by WebKit's Use Selection for Find
    /// command (Cmd-E). Nil when nothing was copied: no range selected, or one in a password field.
    /// Returns false, without calling `completion`, if the selector is unavailable on this OS.
    @discardableResult
    func takeFindStringFromSelection(completion: @escaping @MainActor (String?) -> Void) -> Bool {
        guard let (selector, imp) = method("_executeEditCommand:argument:completion:") else { return false }
        typealias CommandMethod = @convention(c) (NSObject, Selector, NSString, NSString?, @escaping @convention(block) (Bool) -> Void) -> Void
        let pasteboard = NSPasteboard(name: .find)
        let changeCount = pasteboard.changeCount
        // The web process writes the pasteboard synchronously while running the command, before it replies.
        unsafeBitCast(imp, to: CommandMethod.self)(object, selector, "TakeFindStringFromSelection", nil) { _ in
            MainActor.assumeIsolated { completion(pasteboard.changeCount == changeCount ? nil : pasteboard.string(forType: .string)) }
        }
        return true
    }

    /// `_findString:options:maxCount:`, which reports to the web view's `_WKFindDelegate`. No-ops if absent.
    func findString(_ string: String, options: UInt, maxCount: UInt) {
        guard let (selector, imp) = method("_findString:options:maxCount:") else { return }
        typealias FindMethod = @convention(c) (NSObject, Selector, NSString, UInt, UInt) -> Void
        unsafeBitCast(imp, to: FindMethod.self)(object, selector, string as NSString, options, maxCount)
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
