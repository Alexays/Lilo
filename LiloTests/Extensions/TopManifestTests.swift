import WebKit
import XCTest
@testable import Lilo

/// The manifest of every most used store extension (top-manifests.json, from `make top-manifests`) goes through
/// Lilo's preparation and loads in WebKit with no error but a missing file or image, as the fixture holds only
/// manifests and the messages they name, unless top-manifest-errors.txt lists it with why.
@MainActor
final class TopManifestTests: XCTestCase {
    func testTopExtensionManifestsLoadInWebKit() async throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: here.appendingPathComponent("top-manifests.json"))) as? [String: Any])?["extensions"]
                as? [String: [String: Any]]
        )
        let listed = Set(
            try String(contentsOf: here.appendingPathComponent("top-manifest-errors.txt"), encoding: .utf8)
                .split(separator: "\n").filter { !$0.hasPrefix("#") && $0.contains("|") }
                .map { $0.split(separator: "|", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces) }
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("top-manifests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // `id: error` for each error but a missing file or image.
        var errors: Set<String> = []
        for (id, entry) in fixture {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // A manifest strict JSON rejects is kept as its text, which Lilo then fails to read as Chrome does.
            let manifest = try XCTUnwrap(entry["manifest"])
            try ((manifest as? String).map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: manifest))
                .write(to: dir.appendingPathComponent("manifest.json"))
            if let locale = (manifest as? [String: Any])?["default_locale"] as? String {
                let messages = entry["messages"] ?? [String: Any]()
                let localeDir = dir.appendingPathComponent("_locales/\(locale)", isDirectory: true)
                try FileManager.default.createDirectory(at: localeDir, withIntermediateDirectories: true)
                try ((messages as? String).map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: messages))
                    .write(to: localeDir.appendingPathComponent("messages.json"))
            }
            if ProfileExtensionRegistry.prepareForWebKit(at: dir, allowsUserScripts: true) { errors.insert("\(id): preparation degraded") }
            do {
                let webExtension = try await WKWebExtension(resourceBaseURL: dir)
                for case let error as NSError in webExtension.errors where error.code != WKWebExtension.Error.resourceNotFound.rawValue
                    && !error.localizedDescription.hasPrefix("Failed to load image") {
                    errors.insert("\(id): \(error.localizedDescription)")
                }
            } catch {
                errors.insert("\(id): \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(errors.subtracting(listed).sorted(), [], "top extensions WebKit loads with errors: accept them as Chrome does, or list them with why")
        XCTAssertEqual(listed.subtracting(errors).sorted(), [], "listed errors that no longer occur: drop them")
    }
}
