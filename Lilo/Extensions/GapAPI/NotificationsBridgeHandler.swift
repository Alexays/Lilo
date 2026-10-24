import Foundation
import UserNotifications
import os

/// chrome.notifications via UNUserNotificationCenter.
@MainActor
final class NotificationsBridgeHandler: GapHandler {
    @MainActor
    protocol NotificationsCenterClient {
        func add(_ request: UNNotificationRequest) async throws
        func deliveredNotifications() async -> [UNNotification]
        func removeDeliveredNotifications(withIdentifiers identifiers: [String])
        func removePendingNotificationRequests(withIdentifiers identifiers: [String])
        func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
        func authorizationStatus() async -> UNAuthorizationStatus
        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    }

    private struct SystemNotificationsCenterClient: NotificationsCenterClient {
        func add(_ request: UNNotificationRequest) async throws {
            try await UNUserNotificationCenter.current().add(request)
        }

        func deliveredNotifications() async -> [UNNotification] {
            await UNUserNotificationCenter.current().deliveredNotifications()
        }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }

        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }

        func authorizationStatus() async -> UNAuthorizationStatus {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }

        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        }
    }

    /// Button action identifiers are `\(buttonActionPrefix)<index>`, so AppDelegate can recover the
    /// tapped button index and fire chrome.notifications.onButtonClicked.
    static let buttonActionPrefix = "lilo.button."

    /// Shared by notifications without buttons: `.customDismissAction` is what makes a user dismissal
    /// reach AppDelegate as onClosed(byUser: true). Registered at launch and on every category write.
    static let plainCategory = UNNotificationCategory(identifier: "lilo.notification.plain", actions: [], intentIdentifiers: [], options: .customDismissAction)

    private static let logger = Logger(liloCategory: "notifications-bridge")
    private let notificationCenter: NotificationsCenterClient

    /// One category per delivered notification, keyed by prefixed id. UNUserNotificationCenter replaces the whole set on each write,
    /// so the union is kept here; dismissals never reach this handler, so the list is capped by dropping the oldest.
    private var categories: [(id: String, category: UNNotificationCategory)] = []
    private static let maxCategories = 64

    /// Decoded icon bytes and file extension per "<extensionId> <iconUrl>", so repeated posts skip the
    /// base64 decode or file read. Emptied when it grows past a handful of icons.
    private var iconCache: [String: (data: Data, ext: String)] = [:]

    let gapActions: Set<String> = [
        "notifications.create",
        "notifications.clear",
        "notifications.getAll",
        "notifications.update",
        "notifications.getPermissionLevel"
    ]

    init(notificationCenter: NotificationsCenterClient = SystemNotificationsCenterClient()) {
        self.notificationCenter = notificationCenter
    }

    func handle(_ call: GapCall) async -> Any? {
        // The calling extension's installed folder, where a relative `iconUrl` is read from.
        let extensionDirectory = call.registry.loadedExtensions.first { $0.id == call.extensionId }
            .map { URL(fileURLWithPath: $0.sourcePath, isDirectory: true) }
        switch call.action {
        case "notifications.create":
            return await handleCreate(params: call.payload, extensionId: call.extensionId, extensionDirectory: extensionDirectory)
        case "notifications.clear":
            return await handleClear(params: call.payload, extensionId: call.extensionId)
        case "notifications.getAll":
            return await handleGetAll(extensionId: call.extensionId)
        case "notifications.update":
            return await handleUpdate(params: call.payload, extensionId: call.extensionId, extensionDirectory: extensionDirectory)
        case "notifications.getPermissionLevel":
            return await handleGetPermissionLevel()
        default:
            return nil
        }
    }

    // MARK: - Create

    private func handleCreate(params: [String: Any], extensionId: String, extensionDirectory: URL?) async -> [String: Any] {
        await requestPermissionIfNeeded()

        // Chrome treats an empty id like a missing one: each such create is a new notification.
        let requestedId = (params["notificationId"] ?? params["id"]) as? String ?? ""
        let notificationId = requestedId.isEmpty ? UUID().uuidString : requestedId
        let prefixedId = "\(extensionId):\(notificationId)"

        await postNotification(prefixedId: prefixedId, extensionId: extensionId, notificationId: notificationId, options: params, extensionDirectory: extensionDirectory)
        return ["notificationId": notificationId]
    }

    /// Builds the content from Chrome options and delivers it under `prefixedId`. Shared by create and
    /// update: re-adding with the same identifier replaces the delivered notification in place.
    private func postNotification(
        prefixedId: String,
        extensionId: String,
        notificationId: String,
        options: [String: Any],
        extensionDirectory: URL?
    ) async {
        let content = UNMutableNotificationContent()
        content.title = options["title"] as? String ?? ""
        content.body = options["message"] as? String ?? ""
        if let contextMessage = options["contextMessage"] as? String, !contextMessage.isEmpty {
            content.subtitle = contextMessage
        }
        // Chrome priority is -2...2; only elevate the loud end so routine notifications stay passive.
        if let priority = options["priority"] as? Int, priority >= 2 {
            content.interruptionLevel = .timeSensitive
        }

        let buttons = Self.buttonTitles(from: options)
        if !buttons.isEmpty {
            categories.removeAll { $0.id == prefixedId }
            categories.append((prefixedId, Self.makeCategory(id: prefixedId, buttonTitles: buttons)))
            if categories.count > Self.maxCategories { categories.removeFirst() }
            content.categoryIdentifier = prefixedId
            notificationCenter.setNotificationCategories(Set(categories.map(\.category)).union(UNNotificationCategory.terminalAttentionCategories).union([Self.plainCategory]))
        } else {
            content.categoryIdentifier = Self.plainCategory.identifier
        }

        if let iconUrl = options["iconUrl"] as? String, !iconUrl.isEmpty {
            let cacheKey = "\(extensionId) \(iconUrl)"
            var icon = iconCache[cacheKey]
            if icon == nil, let loaded = Self.loadIcon(iconUrl: iconUrl, extensionDirectory: extensionDirectory) {
                if iconCache.count >= 32 { iconCache.removeAll() }
                iconCache[cacheKey] = loaded
                icon = loaded
            }
            if let icon, let fileURL = await Self.writeIconCopy(icon.data, ext: icon.ext),
               let attachment = try? UNNotificationAttachment(identifier: "", url: fileURL, options: nil) {
                content.attachments = [attachment]
            }
        }

        // Persisted on the notification so getAll can report the real shape without a side store.
        content.userInfo = [
            "extensionId": extensionId,
            "notificationId": notificationId,
            "type": options["type"] as? String ?? "basic",
            "iconUrl": options["iconUrl"] as? String ?? "",
            "contextMessage": options["contextMessage"] as? String ?? "",
            "buttons": buttons
        ]

        let request = UNNotificationRequest(identifier: prefixedId, content: content, trigger: nil)
        do { try await notificationCenter.add(request) } catch {
            Self.logger.error("Failed to post notification: \(error.localizedDescription)")
        }
    }

    private static func buttonTitles(from options: [String: Any]) -> [String] {
        guard let buttons = options["buttons"] as? [[String: Any]] else { return [] }
        return buttons.map { ($0["title"] as? String) ?? "" }
    }

    private static func makeCategory(id: String, buttonTitles: [String]) -> UNNotificationCategory {
        let actions = buttonTitles.enumerated().map { index, title in
            UNNotificationAction(identifier: "\(buttonActionPrefix)\(index)", title: title, options: [])
        }
        return UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: .customDismissAction)
    }

    /// Resolves a Chrome `iconUrl` to image bytes: a base64 `data:` URL, or one of the extension's own
    /// files (relative path or extension URL). Remote URLs are skipped.
    private static func loadIcon(iconUrl: String, extensionDirectory: URL?) -> (data: Data, ext: String)? {
        if iconUrl.hasPrefix("data:") {
            guard let commaIndex = iconUrl.firstIndex(of: ","), iconUrl[..<commaIndex].contains(";base64"),
                  let decoded = Data(base64Encoded: String(iconUrl[iconUrl.index(after: commaIndex)...])) else { return nil }
            return (decoded, iconUrl.contains("image/jpeg") ? "jpg" : "png")
        }
        guard let file = resourceFile(for: iconUrl, in: extensionDirectory), let contents = try? Data(contentsOf: file) else { return nil }
        return (contents, file.pathExtension.isEmpty ? "png" : file.pathExtension)
    }

    /// Writes a fresh temp copy off the main thread: the attachment takes ownership of its file.
    private static func writeIconCopy(_ data: Data, ext: String) async -> URL? {
        await Task.detached {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-notif-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: fileURL)
                return fileURL
            } catch {
                return nil
            }
        }.value
    }

    /// The extension file an `iconUrl` names: a relative or root-relative path, or an extension URL
    /// (whose host is the extension). Nil for anything outside the extension's folder.
    private static func resourceFile(for iconUrl: String, in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let path: String
        if let url = URL(string: iconUrl), let scheme = url.scheme?.lowercased() {
            guard scheme == "chrome-extension" else { return nil }
            path = url.path
        } else {
            path = iconUrl.split(separator: "?").first.map(String.init) ?? iconUrl
        }
        let root = directory.standardizedFileURL.path
        let file = directory.appendingPathComponent(path.removingPercentEncoding ?? path).standardizedFileURL
        return file.path.hasPrefix(root + "/") ? file : nil
    }

    // MARK: - Clear

    private func handleClear(params: [String: Any], extensionId: String) async -> [String: Any] {
        let notificationId = params["notificationId"] as? String ?? ""
        let prefixedId = "\(extensionId):\(notificationId)"

        let delivered = await notificationCenter.deliveredNotifications()
        let wasPresent = delivered.contains { $0.request.identifier == prefixedId }

        notificationCenter.removeDeliveredNotifications(withIdentifiers: [prefixedId])
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [prefixedId])
        if let index = categories.firstIndex(where: { $0.id == prefixedId }) {
            categories.remove(at: index)
            notificationCenter.setNotificationCategories(Set(categories.map(\.category)).union(UNNotificationCategory.terminalAttentionCategories).union([Self.plainCategory]))
        }
        return ["wasCleared": wasPresent]
    }

    // MARK: - GetAll

    private func handleGetAll(extensionId: String) async -> [String: Any] {
        let delivered = await notificationCenter.deliveredNotifications()
        var result: [String: [String: Any]] = [:]
        for notification in delivered {
            let info = notification.request.content.userInfo
            guard let extId = info["extensionId"] as? String, extId == extensionId,
                  let notifId = info["notificationId"] as? String else { continue }
            let buttons = (info["buttons"] as? [String]) ?? []
            result[notifId] = [
                "title": notification.request.content.title,
                "message": notification.request.content.body,
                "type": info["type"] as? String ?? "basic",
                "iconUrl": info["iconUrl"] as? String ?? "",
                "contextMessage": info["contextMessage"] as? String ?? "",
                "buttons": buttons.map { ["title": $0] }
            ]
        }
        return result
    }

    // MARK: - Update

    private func handleUpdate(params: [String: Any], extensionId: String, extensionDirectory: URL?) async -> [String: Any] {
        let notificationId = (params["notificationId"] ?? params["id"]) as? String ?? ""
        let prefixedId = "\(extensionId):\(notificationId)"

        // Merge the update onto the existing notification's stored options so unspecified fields
        // survive. UN has no in-place mutation API, so re-adding under the same identifier replaces
        // the delivered notification in place (preserving its identity) rather than clear+recreate.
        let delivered = await notificationCenter.deliveredNotifications()
        guard let existing = delivered.first(where: { $0.request.identifier == prefixedId }) else {
            return ["wasUpdated": false]
        }
        var merged = Self.storedOptions(from: existing.request.content)
        merged.merge(params) { _, new in new }

        await postNotification(prefixedId: prefixedId, extensionId: extensionId, notificationId: notificationId, options: merged, extensionDirectory: extensionDirectory)
        return ["wasUpdated": true]
    }

    /// Rebuilds the Chrome-option dict from a delivered notification's content + persisted userInfo,
    /// so an update can merge over the previous state.
    private static func storedOptions(from content: UNNotificationContent) -> [String: Any] {
        let info = content.userInfo
        var options: [String: Any] = [
            "title": content.title,
            "message": content.body,
            "type": info["type"] as? String ?? "basic",
            "iconUrl": info["iconUrl"] as? String ?? "",
            "contextMessage": info["contextMessage"] as? String ?? ""
        ]
        if let buttons = info["buttons"] as? [String] {
            options["buttons"] = buttons.map { ["title": $0] }
        }
        return options
    }

    // MARK: - Permissions

    private func handleGetPermissionLevel() async -> [String: Any] {
        let status = await notificationCenter.authorizationStatus()
        let granted = status == .authorized || status == .provisional
        return ["level": granted ? "granted" : "denied"]
    }

    private func requestPermissionIfNeeded() async {
        let authorizationStatus = await notificationCenter.authorizationStatus()
        guard authorizationStatus == .notDetermined else { return }
        do { _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound]) } catch { Self.logger.error("Notification permission request failed: \(error.localizedDescription)") }
    }
}
