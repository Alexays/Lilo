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
        "downloads.setUiOptions",
        "downloads.suggestFilename"
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
        if call.action == "downloads.suggestFilename" {
            let context = FilenameContext(registry: ObjectIdentifier(call.registry), extensionId: call.extensionId, pageChannel: call.int("pageChannel"))
            guard let requestId = call.string("requestId"), var request = Self.filenameRequests[requestId] else { return nil }
            guard request.awaiting.remove(context) != nil else { return nil }
            let conflictAction = call.string("conflictAction") ?? "uniquify"
            var error: BridgeError?
            if let filename = call.string("filename"), !filename.isEmpty {
                if !Self.isRelativeFilename(filename) {
                    error = BridgeError("Invalid filename")
                } else if !["uniquify", "overwrite", "prompt"].contains(conflictAction) {
                    error = BridgeError("Invalid conflictAction")
                } else {
                    request.suggestions[call.extensionId] = (filename, conflictAction)
                }
            }
            Self.filenameRequests[requestId] = request
            if request.awaiting.isEmpty { Self.finishFilename(requestId) }
            return error
        }
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
            guard let id = Self.downloadId(from: call), !downloadManager.isPrivateDownload(id: id, profileId: store.profileId),
                  let item = try? store.fetch(id: id) else { return BridgeError("Invalid downloadId") }
            return BridgeError(item.state == .inProgress ? "Download must be dangerous" : "Download must be in progress")
        }
        if call.action == "downloads.search" {
            do {
                return try await Self.searchItems(in: store, matching: call)
                    .filter { !downloadManager.isPrivateDownload(id: $0.id ?? 0, profileId: store.profileId) }
                    .map(Self.chromeDownloadItem)
            } catch {
                return BridgeError(error.localizedDescription)
            }
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
            var requested = call.string("filename")
            if let requested, !Self.isRelativeFilename(requested) {
                return BridgeError("Invalid filename")
            }
            var conflictAction = call.string("conflictAction")
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
            let item = DownloadItem(
                id: nil, url: urlString, filename: ((requested ?? url.lastPathComponent) as NSString).lastPathComponent, destinationPath: "",
                bytesReceived: 0, totalBytes: -1, state: .inProgress, startedAt: Date(), fileMissing: false
            )
            if let suggestion = await Self.suggestFilename(for: item, registry: call.registry) {
                requested = suggestion.filename
                conflictAction = suggestion.conflictAction
            }
            let filename = requested ?? url.lastPathComponent
            let folder = resolvedDownloadsFolder(downloadManager.settingsFolder)
            let target = folder.appendingPathComponent(filename)
            // "uniquify" (the default) lets the backend pick a free name in the folder; "prompt" asks only for a taken one.
            var destination: URL? = conflictAction == "overwrite" ? target : nil
            if call.bool("saveAs") || (conflictAction == "prompt" && FileManager.default.fileExists(atPath: target.path)) {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = target.lastPathComponent
                panel.directoryURL = target.deletingLastPathComponent()
                let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
                guard response == .OK, let chosen = panel.url else { return BridgeError("Download canceled") }
                destination = chosen
            } else if requested?.contains("/") == true {
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                } catch {
                    return BridgeError(error.localizedDescription)
                }
            }
            return bridged { try downloadManager.startExtensionDownload(request: request, suggestedFilename: filename, destination: destination, in: store) }

        case "downloads.erase":
            let items: [DownloadItem]
            do { items = try await Self.searchItems(in: store, matching: call) } catch { return BridgeError(error.localizedDescription) }
            return bridged {
                var erased: [Int64] = []
                for item in items {
                    guard let id = item.id, !downloadManager.isPrivateDownload(id: id, profileId: store.profileId) else { continue }
                    try downloadManager.erase(id: id, in: store)
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
        guard let id = Self.downloadId(from: call), !downloadManager.isPrivateDownload(id: id, profileId: store.profileId),
              (try? store.fetch(id: id)) != nil else {
            return BridgeError("Download not found")
        }
        switch call.action {
        case "downloads.pause":
            await downloadManager.pause(id: id, in: store)
            return nil

        case "downloads.resume":
            await downloadManager.resume(id: id, in: store)
            return nil

        case "downloads.cancel":
            await downloadManager.cancel(id: id, in: store)
            return nil

        case "downloads.open":
            downloadManager.openFile(id: id, in: store)
            return nil

        case "downloads.show":
            downloadManager.showInFinder(id: id, in: store)
            return nil

        case "downloads.removeFile":
            return bridged { () throws -> Any? in
                try downloadManager.removeFile(id: id, in: store)
                return nil
            }

        case "downloads.getFileIcon":
            let size = call.int("size") ?? 32
            return downloadManager.fileIcon(id: id, size: size, in: store).map { "data:image/png;base64,\($0)" }

        default:
            return nil
        }
    }

    /// Chrome takes a path relative to the downloads folder, so nothing may climb out of it or hide.
    private static func isRelativeFilename(_ filename: String) -> Bool {
        !filename.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0.hasPrefix(".") }
    }

    // MARK: - onDeterminingFilename

    /// An extension's worker (no `pageChannel`) or one of its pages, in a profile: the same extension in another one
    /// answers only its own downloads.
    private struct FilenameContext: Hashable {
        let registry: ObjectIdentifier
        let extensionId: String
        let pageChannel: Int?
    }

    /// A download waiting on the contexts that listen to onDeterminingFilename, each answering once.
    private struct FilenameRequest {
        var awaiting: Set<FilenameContext>
        /// In load order: the last one's suggestion wins, as Chrome's most recently installed extension's does.
        let extensionIds: [String]
        var suggestions: [String: FilenameSuggestion] = [:]
        let continuation: CheckedContinuation<FilenameSuggestion?, Never>
        let timeout: Task<Void, Never>
    }
    /// Static: the download manager asks through the window's wiring, which reaches no handler instance.
    private static var filenameRequests: [String: FilenameRequest] = [:]
    private static var nextFilenameRequest = 0
    /// How long extensions get to suggest before the download keeps its own name.
    private static let filenameTimeout: Duration = .seconds(10)

    /// Chrome's onDeterminingFilename for `item`, about to start: what the extensions listening with the downloads permission
    /// suggest, nil when none does. Without a listening context it answers at once and sends nothing.
    static func suggestFilename(for item: DownloadItem, registry: ProfileExtensionRegistry) async -> FilenameSuggestion? {
        let contexts = registry.extensionIds(withPermission: "downloads").flatMap { id in
            registry.gapEvents.contexts(of: id, listeningTo: "downloads.onDeterminingFilename").map {
                FilenameContext(registry: ObjectIdentifier(registry), extensionId: id, pageChannel: $0)
            }
        }
        guard !contexts.isEmpty else { return nil }
        var ids: [String] = []
        for context in contexts where ids.last != context.extensionId { ids.append(context.extensionId) }
        nextFilenameRequest += 1
        let requestId = "lilo-filename-\(nextFilenameRequest)"
        var details = chromeDownloadItem(item)
        // Chrome names the file without its folder here; the download gets its id once it starts.
        details["filename"] = item.filename
        details["id"] = nil
        registry.gapEvents.emit("downloads", "onDeterminingFilename", args: [details, requestId], to: ids)
        return await withCheckedContinuation { continuation in
            filenameRequests[requestId] = FilenameRequest(
                awaiting: Set(contexts), extensionIds: ids, continuation: continuation,
                timeout: Task { @MainActor in
                    guard (try? await Task.sleep(for: Self.filenameTimeout)) != nil else { return }
                    Self.finishFilename(requestId)
                }
            )
        }
    }

    private static func finishFilename(_ requestId: String) {
        guard let request = filenameRequests.removeValue(forKey: requestId) else { return }
        request.timeout.cancel()
        request.continuation.resume(returning: request.extensionIds.reversed().lazy.compactMap { request.suggestions[$0] }.first)
    }

    private static func downloadId(from call: GapCall) -> Int64? {
        (call.int("downloadId") ?? call.int("id")).map(Int64.init)
    }

    private static func searchItems(in store: DownloadStore, matching call: GapCall) async throws -> [DownloadItem] {
        let id = call.int("id").map(Int64.init)
        let url = call.string("url")
        let filename = call.string("filename")
        let query = (call.payload["query"] as? [String]) ?? call.string("query").map { [$0] } ?? []
        // Chrome reads 0 as unlimited; the cap keeps the read bounded.
        let limit = call.int("limit").map { $0 > 0 ? min($0, maxSearchResults) : maxSearchResults } ?? maxSearchResults
        let states: [DownloadState] = switch call.string("state") {
        case "in_progress": [.inProgress, .paused]
        case "interrupted": [.interrupted]
        case "complete": [.complete]
        default: []
        }
        return try await Task.detached {
            try store.search(states: states, query: query, url: url, filename: filename, id: id, limit: limit)
        }.value
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
