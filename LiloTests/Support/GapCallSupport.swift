import Foundation
@testable import Lilo

/// A caller's profile registry for handler tests that need one but nothing installed in it.
@MainActor
let gapTestRegistry: ProfileExtensionRegistry = {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gap-tests-\(getpid())")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // One folder per test process, named by its pid: an exit handler can capture nothing.
    atexit { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("gap-tests-\(getpid())")) }
    // Outlives every test, so it keeps its own id rather than a pooled one.
    return try! makeTestExtensionRegistry(profileId: UUID(), in: directory)
}()

extension GapHandler {
    /// Runs `message` as the gap router would, from the extension its `extensionId` names.
    func handle(_ message: BridgeMessage, registry: ProfileExtensionRegistry = gapTestRegistry) async -> Any? {
        let extensionId = message.string("extensionId") ?? "test-extension"
        return await handle(GapCall(
            action: message.action,
            extensionId: extensionId,
            context: registry.context(for: extensionId),
            registry: registry,
            payload: message.payload
        ))
    }
}
