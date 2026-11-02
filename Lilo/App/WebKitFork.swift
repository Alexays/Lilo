import Foundation
import WebKit

/// Lilo's WebKit fork, embedded in Contents/Frameworks with `LiloFork`, a copy of Lilo whose dyld environment loads it.
/// The fork runs only while it holds every WebKit fix of the installed system: `LiloWebKitForkCoversSafari` is the newest
/// release whose security advisories it covers, checked when it is built. A newer Safari runs the system WebKit.
enum WebKitFork {
    /// Replaces this process with `LiloFork` when the fork covers the installed Safari; returns on the system WebKit.
    static func execIfCovered() {
        guard ProcessInfo.processInfo.environment["LILO_SYSTEM_WEBKIT"] == nil,
              Bundle(for: WKWebView.self).bundlePath.hasPrefix("/System/"),
              let covered = Bundle.main.object(forInfoDictionaryKey: "LiloWebKitForkCoversSafari") as? String,
              let safari = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              // A Background Security Improvement adds a suffix ("27.0.1 (a)"): newer than any fork knows.
              safari.allSatisfy({ $0.isNumber || $0 == "." }),
              safari.compare(covered, options: .numeric) != .orderedDescending,
              // The fork is built for one macOS: Safari follows the system's version, so a major apart is another system.
              safari.split(separator: ".").first == covered.split(separator: ".").first,
              let fork = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LiloFork").path
        else { return }
        // Only returns when the exec fails (an Intel Mac, the fork being Apple silicon only): Lilo then goes on as it is.
        unsafe execv(fork, CommandLine.unsafeArgv)
    }
}
