import Foundation
import AppKit
import WebKit

/// Implements the chrome.downloads Gap API as a BridgeHandler.
/// Handles extension-initiated downloads and queries.
@MainActor
final class DownloadsBridgeHandler: GapHandler {

    let gapActions: Set<String> = [
        "downloads.download",
        "downloads.search",
        "downloads.pause",
        "downloads.resume",
        "downloads.cancel",
        "downloads.erase",
        "downloads.open",
        "downloads.show",
        "downloads.removeFile",
        "downloads.getFileIcon",
        "downloads.showDefaultFolder",
        "downloads.acceptDanger",
        "downloads.setUiOptions"
    ]

    private static let maxSearchResults = 1000

    private let managerProvider: () -> DownloadManager?
    /// The calling extension's profile store, resolved from its registry.
    private let storeProvider: (ProfileExtensionRegistry) -> DownloadStore?

    init(
        managerProvider: @escaping () -> DownloadManager?,
        storeProvider: @escaping (ProfileExtensionRegistry) -> DownloadStore?
    ) {
        self.managerProvider = managerProvider
        self.storeProvider = storeProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        // Changes the UI only: answered whichever profile is active.
        if call.action == "downloads.setUiOptions" {
            guard call.registry.heldPermissions(of: call.extensionId).contains("downloads.ui") else {
                return BridgeError("downloads.setUiOptions requires the \"downloads.ui\" permission")
            }
            return call.registry.setDownloadUiEnabled(call.bool("enabled"), by: call.extensionId) ? nil : BridgeError("Another extension has disabled the download UI")
        }
        // Resolved per call so registration order against the factory's wiring does not matter.
        guard let downloadManager = managerProvider(),
              let store = storeProvider(call.registry) else {
            return BridgeError("Download manager unavailable")
        }

        if call.action == "downloads.acceptDanger" {
            // Lilo never marks a download dangerous, so there is never a danger to accept.
            guard let id = Self.downloadId(from: call), !downloadManager.isPrivateDownload(id: id),
                  let item = try? store.fetch(id: id) else { return BridgeError("Invalid downloadId") }
            return BridgeError(item.state == .inProgress ? "Download must be dangerous" : "Download must be in progress")
        }
        if call.action == "downloads.search" {
            do {
                return try await Self.searchItems(in: store, matching: call)
                    .filter { !downloadManager.isPrivateDownload(id: $0.id ?? 0) }
                    .map(Self.chromeDownloadItem)
            } catch {
                return BridgeError(error.localizedDescription)
            }
        }
        // The manager acts on the active profile's store, where another profile's row ids name
        // unrelated downloads: such a caller only gets search.
        guard store === downloadManager.store else {
            return BridgeError("Downloads can only be changed while the extension's profile is active")
        }

        switch call.action {
        case "downloads.download":
            guard let urlString = call.string("url"),
                  let url = URL(string: urlString) else {
                return BridgeError("Invalid URL")
            }
            // Only network/data sources, never `file://` (would let an extension exfiltrate a local
            // file into the downloads pipeline). A blob URL lives in the creating page's process,
            // which the native download session cannot reach.
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "blob" {
                return BridgeError("blob: URLs cannot be downloaded in Lilo; pass a data: URL instead")
            }
            guard ["http", "https", "data"].contains(scheme) else {
                return BridgeError("Unsupported download URL scheme")
            }
            var request = URLRequest(url: url)
            request.httpMethod = call.string("method") ?? "GET"
            request.httpBody = call.string("body").map { Data($0.utf8) }
            for header in call.payload["headers"] as? [[String: Any]] ?? [] {
                guard let name = header["name"] as? String, let value = header["value"] as? String else { continue }
                request.setValue(value, forHTTPHeaderField: name)
            }
            // The session's own jar is not the profile's: send the profile's cookies for the URL.
            if scheme != "data", request.value(forHTTPHeaderField: "Cookie") == nil {
                let cookies = await WKWebsiteDataStore(forIdentifier: call.registry.profileId).httpCookieStore.cookies(for: url)
                request.httpShouldHandleCookies = false
                for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
            let filename = Self.sanitizeFilename(call.string("filename")) ?? url.lastPathComponent
            let folder = resolvedDownloadsFolder(downloadManager.settingsFolder)
            // "uniquify" (the default) and "prompt" let the backend pick a free name in the folder.
            var destination: URL? = call.string("conflictAction") == "overwrite" ? folder.appendingPathComponent(filename) : nil
            if call.bool("saveAs") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = filename
                panel.directoryURL = folder
                let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
                guard response == .OK, let chosen = panel.url else { return BridgeError("Download canceled") }
                destination = chosen
            }
            return bridged { try downloadManager.startExtensionDownload(request: request, suggestedFilename: filename, destination: destination) }

        case "downloads.erase":
            let items: [DownloadItem]
            do { items = try await Self.searchItems(in: store, matching: call) } catch { return BridgeError(error.localizedDescription) }
            return bridged {
                var erased: [Int64] = []
                for item in items {
                    guard let id = item.id, !downloadManager.isPrivateDownload(id: id) else { continue }
                    try downloadManager.erase(id: id)
                    erased.append(id)
                }
                return erased
            }

        case "downloads.showDefaultFolder":
            NSWorkspace.shared.open(downloadManager.settingsFolder ?? BuildIdentity.defaultDownloadsDirectory)
            return nil

        default:
            break
        }

        // Every remaining action addresses one download, which must exist outside private spaces.
        guard let id = Self.downloadId(from: call), !downloadManager.isPrivateDownload(id: id),
              (try? store.fetch(id: id)) != nil else {
            return BridgeError("Download not found")
        }
        switch call.action {
        case "downloads.pause":
            await downloadManager.pause(id: id)
            return nil

        case "downloads.resume":
            await downloadManager.resume(id: id)
            return nil

        case "downloads.cancel":
            await downloadManager.cancel(id: id)
            return nil

        case "downloads.open":
            downloadManager.openFile(id: id)
            return nil

        case "downloads.show":
            downloadManager.showInFinder(id: id)
            return nil

        case "downloads.removeFile":
            return bridged { () throws -> Any? in
                try downloadManager.removeFile(id: id)
                return nil
            }

        case "downloads.getFileIcon":
            let size = call.int("size") ?? 32
            return downloadManager.fileIcon(id: id, size: size).map { "data:image/png;base64,\($0)" }

        default:
            return nil
        }
    }

    private static func downloadId(from call: GapCall) -> Int64? {
        (call.int("downloadId") ?? call.int("id")).map(Int64.init)
    }

    /// Reduce a JS-supplied `filename` to a single safe path component: strip directory separators
    /// and parent-traversal so the suggested name can't escape the downloads directory downstream.
    private static func sanitizeFilename(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lastComponent = (raw as NSString).lastPathComponent
        let cleaned = lastComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let trimmed = cleaned.drop { $0 == "." }
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    private static func searchItems(in store: DownloadStore, matching call: GapCall) async throws -> [DownloadItem] {
        let id = call.int("id").map(Int64.init)
        let url = call.string("url")
        let filename = call.string("filename")
        let query = (call.payload["query"] as? [String])?.joined(separator: " ")
            ?? call.string("query")
        // Chrome reads 0 as unlimited; the cap keeps the read bounded.
        let limit = call.int("limit").map { $0 > 0 ? min($0, maxSearchResults) : maxSearchResults } ?? maxSearchResults

        let state = chromeState(from: call.string("state"))
        // in_progress spans two stored states, so it stays a Swift filter; the others hit the SQL predicate.
        let sqlState = state == .inProgress ? nil : state
        let items = try await Task.detached {
            try store.search(state: sqlState, query: query, url: url, filename: filename, id: id, limit: limit)
        }.value
        guard state == .inProgress else { return items }
        return items.filter { $0.state == .inProgress || $0.state == .paused }
    }

    private static func chromeState(from value: String?) -> DownloadState? {
        switch value {
        case "in_progress": return .inProgress
        case "interrupted": return .interrupted
        case "complete": return .complete
        default: return nil
        }
    }

    static func chromeState(for item: DownloadItem) -> String {
        switch item.state {
        case .inProgress, .paused: return "in_progress"
        case .complete: return "complete"
        case .interrupted: return "interrupted"
        }
    }

    // Formatter construction is expensive (ICU setup) and this mapper runs per progress tick.
    private static let isoFormatter = ISO8601DateFormatter()

    static func chromeDownloadItem(_ item: DownloadItem) -> [String: Any] {
        var data: [String: Any] = [
            "id": item.id ?? 0,
            "url": item.url,
            "filename": item.destinationPath,
            "state": chromeState(for: item),
            "paused": item.state == .paused,
            "canResume": item.canResume,
            "danger": "safe",
            "exists": !item.fileMissing,
            "bytesReceived": item.bytesReceived,
            "totalBytes": item.totalBytes,
            "fileSize": item.totalBytes,
            "startTime": isoFormatter.string(from: item.startedAt)
        ]
        if let endedAt = item.endedAt {
            data["endTime"] = isoFormatter.string(from: endedAt)
        }
        if let mimeType = item.mimeType {
            data["mime"] = mimeType
        }
        if let error = item.error {
            data["error"] = error
        }
        return data
    }
}
