import Foundation
import Metal
import WebKit

/// WebKit's experimental and internal-debug feature flags behind `about:config`, via private API. The enumerators are class methods
/// returning `_WKFeature` metadata; state is per instance via `_setEnabled:forFeature:`, and metadata is built once.
@MainActor
enum WKFeatureFlags {
    enum Kind: String { case experimental, debug }

    struct Feature {
        let key: String
        let name: String
        let details: String
        let kind: Kind
        let defaultValue: Bool
    }

    private typealias SetFn = @convention(c) (NSObject, Selector, ObjCBool, AnyObject) -> Void
    private static let setSelector = NSSelectorFromString("_setEnabled:forFeature:")

    /// WebKit-experimental flags Lilo turns ON by default for web compatibility or speed (all are OFF in
    /// stock WebKit). These become Lilo's effective default; users can still flip them in about:config.
    private static let defaultsOn: Set<String> = [
        // `<link rel=prefetch>`: a page a site announces as next opens from the cache.
        "LinkPrefetchEnabled",
        "CloseWatcherEnabled",
        "RequestIdleCallbackEnabled",
        "SelectShowPickerEnabled",
        "CanvasFiltersEnabled",
        "ScreenOrientationLockingAPIEnabled",
        "CSSFontVariantEmojiEnabled",
        "CSSTextTransformMathAutoEnabled",
        "CSSDPropertyEnabled"
    ]
    /// A virtual machine's paravirtual GPU cannot read a canvas back (getImageData throws InvalidStateError, as on GitHub's macOS
    /// runners): canvases draw in memory, in the page's own process, there and wherever Metal finds no GPU.
    private static let graphicsOverrides: [String: Bool] = MTLCreateSystemDefaultDevice().map({ $0.name.contains("Paravirtual") }) ?? true
        ? ["CanvasUsesAcceleratedDrawing": false, "UseGPUProcessForCanvasRenderingEnabled": false]
        : [:]
    /// WebKit's own Screen Time client is off, as in Safari: Lilo's `STWebpageController` is the single one.
    private static let baselineOverrides: [String: Bool] =
        Dictionary(uniqueKeysWithValues: defaultsOn.map { ($0, true) })
            .merging(["ScreenTimeEnabled": false]) { $1 }
            .merging(graphicsOverrides) { $1 }

    /// Canonical `_WKFeature` objects keyed by their stable feature key. Built once.
    private static let featureObjects: [String: NSObject] = {
        var map: [String: NSObject] = [:]
        for selectorName in ["_experimentalFeatures", "_internalDebugFeatures"] {
            for object in rawFeatures(selectorName) {
                if let key = property("key", of: object) as? String { map[key] = object }
            }
        }
        return map
    }()

    /// Metadata for every (non-hidden) feature, for the UI. Built once.
    static let all: [Feature] = {
        var features: [Feature] = []
        for (kind, selectorName) in [(Kind.experimental, "_experimentalFeatures"), (.debug, "_internalDebugFeatures")] {
            for object in rawFeatures(selectorName) {
                guard let key = property("key", of: object) as? String,
                      (property("isHidden", of: object) as? NSNumber)?.boolValue != true else { continue }
                let webkitDefault = (property("defaultValue", of: object) as? NSNumber)?.boolValue ?? false
                features.append(Feature(
                    key: key,
                    name: (property("name", of: object) as? String) ?? key,
                    details: (property("details", of: object) as? String) ?? "",
                    kind: kind,
                    // Lilo's effective default: its baseline overrides WebKit's.
                    defaultValue: baselineOverrides[key] ?? webkitDefault
                ))
            }
        }
        return features
    }()

    /// Applies persisted overrides (`key -> enabled`) to a preferences instance, before its web view
    /// is created. Unknown keys (e.g. removed in a WebKit update) are skipped.
    static func apply(_ overrides: [String: Bool], to preferences: WKPreferences) {
        // Lilo's parity defaults first, then user overrides win.
        let effective = baselineOverrides.merging(overrides) { _, user in user }
        guard !effective.isEmpty, preferences.responds(to: setSelector) else { return }
        let setFn = unsafeBitCast(preferences.method(for: setSelector), to: SetFn.self)
        for (key, enabled) in effective {
            guard let feature = featureObjects[key] else { continue }
            setFn(preferences, setSelector, ObjCBool(enabled), feature)
        }
    }

    private static func rawFeatures(_ selectorName: String) -> [NSObject] {
        let selector = NSSelectorFromString(selectorName)
        let cls: AnyObject = WKPreferences.self  // both enumerators are class methods
        guard cls.responds(to: selector),
              let array = cls.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [] }
        return array
    }

    /// KVC read of a `_WKFeature` property: nil when WebKit renames it, instead of raising.
    private static func property(_ key: String, of feature: NSObject) -> Any? {
        feature.responds(to: NSSelectorFromString(key)) ? feature.value(forKey: key) : nil
    }
}
