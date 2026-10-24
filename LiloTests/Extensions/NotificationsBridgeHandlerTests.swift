import XCTest
import UserNotifications
@testable import Lilo

@MainActor
final class NotificationsBridgeHandlerTests: XCTestCase {
    private final class NotificationCenterSpy: NotificationsBridgeHandler.NotificationsCenterClient {
        var addedRequests: [UNNotificationRequest] = []
        var delivered: [UNNotification] = []
        var removedDeliveredIdentifiers: [String] = []
        var removedPendingIdentifiers: [String] = []
        var categories: Set<UNNotificationCategory> = []
        var status: UNAuthorizationStatus = .authorized

        func add(_ request: UNNotificationRequest) async throws {
            addedRequests.append(request)
        }

        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
            self.categories = categories
        }

        func deliveredNotifications() async -> [UNNotification] {
            delivered
        }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            removedDeliveredIdentifiers.append(contentsOf: identifiers)
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            removedPendingIdentifiers.append(contentsOf: identifiers)
        }

        func authorizationStatus() async -> UNAuthorizationStatus {
            status
        }

        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            status = .authorized
            return true
        }
    }

    func test_handledActions_contains_expected_keys() {
        let handler = NotificationsBridgeHandler()
        XCTAssertTrue(handler.gapActions.contains("notifications.create"))
        XCTAssertTrue(handler.gapActions.contains("notifications.clear"))
        XCTAssertTrue(handler.gapActions.contains("notifications.getAll"))
        XCTAssertTrue(handler.gapActions.contains("notifications.update"))
    }

    func test_create_returns_notificationId() async throws {
        let notificationCenter = NotificationCenterSpy()
        let handler = NotificationsBridgeHandler(notificationCenter: notificationCenter)
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.create",
            "payload": [
                "extensionId": "test-ext",
                "notificationId": "n1",
                "title": "Test",
                "message": "Hello",
                "type": "basic",
                "iconUrl": ""
            ] as [String: Any]
        ]))
        let result = await handler.handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["notificationId"] as? String, "n1")
        XCTAssertEqual(notificationCenter.addedRequests.first?.identifier, "test-ext:n1")
    }

    func test_create_without_id_generates_id() async throws {
        let handler = NotificationsBridgeHandler(notificationCenter: NotificationCenterSpy())
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.create",
            "payload": [
                "extensionId": "test-ext",
                "title": "Test",
                "message": "Body"
            ] as [String: Any]
        ]))
        let result = await handler.handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        let id = try XCTUnwrap(dict["notificationId"] as? String)
        XCTAssertFalse(id.isEmpty, "Generated ID must not be empty")
    }

    func test_create_with_empty_id_generates_a_fresh_id_each_time() async throws {
        let handler = NotificationsBridgeHandler(notificationCenter: NotificationCenterSpy())
        var ids: [String] = []
        for _ in 0..<2 {
            let msg = try XCTUnwrap(BridgeMessage(dictionary: [
                "action": "notifications.create",
                "payload": ["extensionId": "test-ext", "notificationId": "", "title": "T", "message": "B"] as [String: Any]
            ]))
            let result = await handler.handle(msg)
            let dict = try XCTUnwrap(result as? [String: Any])
            ids.append(try XCTUnwrap(dict["notificationId"] as? String))
        }
        XCTAssertFalse(ids[0].isEmpty)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func test_clear_returns_false_when_not_present() async throws {
        let notificationCenter = NotificationCenterSpy()
        let handler = NotificationsBridgeHandler(notificationCenter: notificationCenter)
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.clear",
            "payload": ["extensionId": "test-ext", "notificationId": "nonexistent"]
        ]))
        let result = await handler.handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["wasCleared"] as? Bool, false)
        XCTAssertEqual(notificationCenter.removedDeliveredIdentifiers, ["test-ext:nonexistent"])
        XCTAssertEqual(notificationCenter.removedPendingIdentifiers, ["test-ext:nonexistent"])
    }

    func test_getAll_returns_dict() async throws {
        let handler = NotificationsBridgeHandler(notificationCenter: NotificationCenterSpy())
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.getAll",
            "payload": ["extensionId": "test-ext"]
        ]))
        let result = await handler.handle(msg)
        XCTAssertNotNil(result as? [String: Any], "getAll should return a dict")
    }

    func test_create_maps_options_to_content() async throws {
        let notificationCenter = NotificationCenterSpy()
        let handler = NotificationsBridgeHandler(notificationCenter: notificationCenter)
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.create",
            "payload": [
                "extensionId": "test-ext",
                "notificationId": "n1",
                "title": "Title",
                "message": "Body",
                "contextMessage": "Context",
                "type": "basic",
                "buttons": [["title": "Yes"], ["title": "No"]]
            ] as [String: Any]
        ]))
        _ = await handler.handle(msg)

        let content = try XCTUnwrap(notificationCenter.addedRequests.first?.content)
        XCTAssertEqual(content.subtitle, "Context")
        XCTAssertEqual(content.categoryIdentifier, "test-ext:n1")
        XCTAssertEqual(content.userInfo["type"] as? String, "basic")
        XCTAssertEqual(content.userInfo["buttons"] as? [String], ["Yes", "No"])
    }

    // The button action identifiers create() registers must be exactly what AppDelegate parses back
    // into an onButtonClicked index: this is the seam that makes button taps route.
    func test_create_attaches_an_icon_from_the_extension_files_and_never_outside_them() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notif-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try makeTestExtensionRegistry(in: directory)
        let extDir = try createMinimalExtension(named: "notifier", in: directory)
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("icons"), withIntermediateDirectories: true)
        // A 1x1 PNG.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        try png.write(to: extDir.appendingPathComponent("icons/48.png"))
        try await registry.load(from: extDir)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let notificationCenter = NotificationCenterSpy()
        let handler = NotificationsBridgeHandler(notificationCenter: notificationCenter)

        for iconUrl in ["icons/48.png", "chrome-extension://\(extensionId)/icons/48.png", "../../../etc/hosts"] {
            let msg = try XCTUnwrap(BridgeMessage(dictionary: [
                "action": "notifications.create",
                "payload": ["extensionId": extensionId, "title": "T", "message": "M", "iconUrl": iconUrl]
            ]))
            _ = await handler.handle(msg, registry: registry)
        }

        XCTAssertEqual(notificationCenter.addedRequests.map { $0.content.attachments.count }, [1, 1, 0])
        let sourcePath = try XCTUnwrap(registry.loadedExtensions.first?.sourcePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePath + "/icons/48.png"), "the extension keeps its own icon file")
    }

    func test_create_registers_button_actions_with_routable_identifiers() async throws {
        let notificationCenter = NotificationCenterSpy()
        let handler = NotificationsBridgeHandler(notificationCenter: notificationCenter)
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.create",
            "payload": [
                "extensionId": "test-ext",
                "notificationId": "n1",
                "title": "T",
                "message": "M",
                "buttons": [["title": "First"], ["title": "Second"]]
            ] as [String: Any]
        ]))
        _ = await handler.handle(msg)

        let category = try XCTUnwrap(notificationCenter.categories.first { $0.identifier == "test-ext:n1" })
        let identifiers = category.actions.map(\.identifier)
        XCTAssertEqual(identifiers, ["lilo.button.0", "lilo.button.1"])
        XCTAssertTrue(category.options.contains(.customDismissAction), "dismissals must reach AppDelegate as onClosed(byUser: true)")
        XCTAssertTrue(notificationCenter.categories.contains(NotificationsBridgeHandler.plainCategory), "a category write must keep the plain category")

        // Round-trip each identifier the way AppDelegate.handleNotificationResponse does.
        for (expectedIndex, identifier) in identifiers.enumerated() {
            XCTAssertTrue(identifier.hasPrefix(NotificationsBridgeHandler.buttonActionPrefix))
            let parsed = Int(identifier.dropFirst(NotificationsBridgeHandler.buttonActionPrefix.count))
            XCTAssertEqual(parsed, expectedIndex)
        }
    }

    func test_create_without_buttons_uses_the_shared_dismissable_category() async throws {
        let notificationCenter = NotificationCenterSpy()
        let handler = NotificationsBridgeHandler(notificationCenter: notificationCenter)
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.create",
            "payload": ["extensionId": "test-ext", "notificationId": "n1", "title": "T", "message": "M"] as [String: Any]
        ]))
        _ = await handler.handle(msg)
        XCTAssertTrue(notificationCenter.categories.isEmpty, "the plain category is registered at launch, not per notification")
        XCTAssertEqual(notificationCenter.addedRequests.first?.content.categoryIdentifier, NotificationsBridgeHandler.plainCategory.identifier)
        XCTAssertTrue(NotificationsBridgeHandler.plainCategory.options.contains(.customDismissAction))
    }

    func test_update_does_not_clear_when_absent() async throws {
        let notificationCenter = NotificationCenterSpy()
        let handler = NotificationsBridgeHandler(notificationCenter: notificationCenter)
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.update",
            "payload": ["extensionId": "test-ext", "notificationId": "missing", "title": "New"] as [String: Any]
        ]))
        let result = await handler.handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["wasUpdated"] as? Bool, false)
        // Update must never fall back to remove+recreate.
        XCTAssertTrue(notificationCenter.removedDeliveredIdentifiers.isEmpty)
        XCTAssertTrue(notificationCenter.addedRequests.isEmpty)
    }

    func test_getPermissionLevel_reflects_authorization() async throws {
        let notificationCenter = NotificationCenterSpy()
        notificationCenter.status = .denied
        let handler = NotificationsBridgeHandler(notificationCenter: notificationCenter)
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "notifications.getPermissionLevel",
            "payload": [:]
        ]))
        let result = await handler.handle(msg)
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["level"] as? String, "denied")
    }
}
