import CoreServices
import Foundation
import os

/// Gatekeeper provenance for downloaded files. Lilo isn't sandboxed, so WebKit/LaunchServices
/// don't stamp `com.apple.quarantine` automatically; we do it ourselves on completion.
enum DownloadQuarantine {
    private static let logger = Logger(liloCategory: "downloads")

    /// Kept tight to avoid prompt fatigue; archives (.zip/.iso) get quarantine on their contents.
    private static let riskyExtensions: Set<String> = [
        "app", "dmg", "pkg", "mpkg", "command", "tool", "sh", "bash", "zsh",
        "scpt", "scptd", "applescript", "action", "workflow", "terminal", "jar"
    ]

    static func isRisky(_ url: URL) -> Bool {
        riskyExtensions.contains(url.pathExtension.lowercased())
    }

    /// macOS clears the quarantine record once the user approves the first open.
    static func isQuarantined(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey])
        return values?.quarantineProperties != nil
    }

    /// No-op if the file is missing or already carries a record naming its agent. WebKit's own record names none, and
    /// Gatekeeper then reads "(null) downloaded this file": that one is completed.
    static func stamp(path: String, source: String?) {
        var url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        guard existing?[kLSQuarantineAgentNameKey as String] == nil else { return }
        var properties = existing ?? [:]
        properties[kLSQuarantineTypeKey as String] = properties[kLSQuarantineTypeKey as String] ?? kLSQuarantineTypeWebDownload as String
        properties[kLSQuarantineAgentNameKey as String] = "Lilo"
        if let source, let sourceURL = URL(string: source) {
            properties[kLSQuarantineDataURLKey as String] = sourceURL
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do {
            try url.setResourceValues(values)
        } catch {
            logger.error("Failed to stamp quarantine on \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }
}
