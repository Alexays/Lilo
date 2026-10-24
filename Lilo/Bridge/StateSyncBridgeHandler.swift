import Foundation

/// Handles `requestBrowserStateSync` messages from the Svelte chrome. The UI sends this when it
/// detects a gap in the `stateSeq` sequence (a lost JS delivery), requesting a full-state resync
/// for a space. Full state is always the response to a resync, never a special case.
@MainActor
final class StateSyncBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = ["requestBrowserStateSync"]

    /// Called with the parsed `spaceId` from the payload, or `nil` when the space is absent or
    /// unparseable. The caller is responsible for resolving a nil to the active space.
    private let emitFullState: @MainActor (UUID?) -> Void

    init(emitFullState: @MainActor @escaping (UUID?) -> Void) {
        self.emitFullState = emitFullState
    }

    func handle(message: BridgeMessage) async -> Any? {
        // `spaceId` is optional: a missing or malformed value means "active space".
        emitFullState(message.uuid("spaceId"))
        return nil
    }

    /// The space that receives the resync: `requested` when cached, else `activeSpaceId` only if it is cached itself, so a space still
    /// loading at startup never makes `emitSpaceBrowserChange` silently no-op. Nil when no space is available.
    static func resolvedSpaceId(
        requested: UUID?,
        isCached: (UUID) -> Bool,
        activeSpaceId: UUID?
    ) -> UUID? {
        if let id = requested, isCached(id) { return id }
        if let id = activeSpaceId, isCached(id) { return id }
        return nil
    }
}
