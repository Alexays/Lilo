import Foundation

/// chrome.omnibox bridge, registered on both the UI `BridgeRouter` (address-bar input, fanned out to the keyword's extension as events)
/// and the extension's `GapBridgeRouter` (suggest replies, matched to their address-bar session by `requestId`).
@MainActor
final class OmniboxBridgeHandler: BridgeHandler {
    // The address bar's UI actions. The gap actions (extension to native) reach this handler through
    // `OmniboxGapRelay`, which registers them on the gap router.
    let handledActions: Set<String> = [
        "omniboxInputStarted", "omniboxInputChanged", "omniboxInputEntered", "omniboxInputCancelled", "omniboxDeleteSuggestion"
    ]

    private let resolveKeywordOwner: (String) -> String?
    private let emitToExtension: (_ event: String, _ args: [Any], _ extensionId: String) -> Void
    private weak var bridgeRouter: BridgeRouter?

    private struct PendingRequest { let sessionId: String; let ownerId: String }
    private var pendingByRequestId: [String: PendingRequest] = [:]
    /// Superseded-but-still-authorizable requests, one per session at most: a stale suggest reply
    /// must stay recognized (dropped silently, not an error) without retaining every old request.
    private var supersededByRequestId: [String: PendingRequest] = [:]
    private var latestRequestBySession: [String: String] = [:]
    private var ownerBySession: [String: String] = [:]
    private var defaultSuggestions: [String: String] = [:]

    init(
        resolveKeywordOwner: @escaping (String) -> String?,
        emitToExtension: @escaping (_ event: String, _ args: [Any], _ extensionId: String) -> Void,
        bridgeRouter: BridgeRouter
    ) {
        self.resolveKeywordOwner = resolveKeywordOwner
        self.emitToExtension = emitToExtension
        self.bridgeRouter = bridgeRouter
    }

    /// Production wiring over the profile's live extension registry.
    convenience init(registryProvider: @escaping () -> ProfileExtensionRegistry?, bridgeRouter: BridgeRouter) {
        self.init(
            resolveKeywordOwner: { registryProvider()?.extensionId(forOmniboxKeyword: $0) },
            emitToExtension: { event, args, id in
                registryProvider()?.gapEvents.emit("omnibox", event, args: args, to: [id])
            },
            bridgeRouter: bridgeRouter
        )
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {

        // MARK: UI bridge (address bar to extension)

        case "omniboxInputStarted":
            if let owner = owner(forQuery: message.string("query") ?? "") {
                if let sessionId = message.string("sessionId") { ownerBySession[sessionId] = owner.id }
                emitToExtension("onInputStarted", [], owner.id)
            }
            return nil

        case "omniboxInputChanged":
            guard let sessionId = message.string("sessionId"),
                  let owner = owner(forQuery: message.string("query") ?? "") else { return nil }
            let requestId = UUID().uuidString
            // The new input supersedes the session's previous pending request; keeping every one
            // would leak an entry each time a suggest reply or cancel never arrives.
            if let supersededRequestId = latestRequestBySession[sessionId],
               let superseded = pendingByRequestId.removeValue(forKey: supersededRequestId) {
                supersededByRequestId = supersededByRequestId.filter { $0.value.sessionId != sessionId }
                supersededByRequestId[supersededRequestId] = superseded
            }
            pendingByRequestId[requestId] = PendingRequest(sessionId: sessionId, ownerId: owner.id)
            latestRequestBySession[sessionId] = requestId
            ownerBySession[sessionId] = owner.id
            emitToExtension("onInputChanged", [requestId, owner.text], owner.id)
            return nil

        case "omniboxInputEntered":
            guard let owner = owner(forQuery: message.string("query") ?? "") else { return nil }
            // `text` overrides the typed remainder when the user accepted a specific suggestion
            // (Chrome fires onInputEntered with the chosen suggestion's `content`).
            let text = message.string("text") ?? owner.text
            let disposition = message.string("disposition") ?? "currentTab"
            emitToExtension("onInputEntered", [text, disposition], owner.id)
            if let sessionId = message.string("sessionId") { endSession(sessionId) }
            return nil

        case "omniboxDeleteSuggestion":
            if let owner = owner(forQuery: message.string("query") ?? ""), let text = message.string("text") {
                emitToExtension("onDeleteSuggestion", [text], owner.id)
            }
            return nil

        case "omniboxInputCancelled":
            if let sessionId = message.string("sessionId") {
                if let owner = ownerBySession[sessionId] { emitToExtension("onInputCancelled", [], owner) }
                endSession(sessionId)
            }
            return nil

        default:
            return BridgeError("Unhandled omnibox action: \(message.action)")
        }
    }

    /// An entered or cancelled session keeps nothing: a late suggest reply for it is unknown.
    private func endSession(_ sessionId: String) {
        latestRequestBySession[sessionId] = nil
        ownerBySession[sessionId] = nil
        pendingByRequestId = pendingByRequestId.filter { $0.value.sessionId != sessionId }
        supersededByRequestId = supersededByRequestId.filter { $0.value.sessionId != sessionId }
    }

    // MARK: - Gap bridge (extension to native), through `OmniboxGapRelay`

    func setDefaultSuggestion(_ call: GapCall) {
        let description = (call.payload["suggestion"] as? [String: Any])?["description"] as? String
            ?? call.string("description")
        if let description { defaultSuggestions[call.extensionId] = description }
    }

    /// The extension's suggest() reply for `requestId`, forwarded to the address bar that asked.
    func sendSuggestions(_ call: GapCall) -> Any? {
        let extensionId = call.extensionId
        guard let requestId = call.string("requestId") else { return BridgeError("Malformed omnibox suggestions") }
        // Authorize: the replying extension must own the request, and it must still be the latest
        // request for its session (otherwise the user has typed on: drop the stale reply).
        let pending = pendingByRequestId[requestId] ?? supersededByRequestId[requestId]
        guard let pending, pending.ownerId == extensionId else {
            return BridgeError("Unknown or unauthorized omnibox request")
        }
        pendingByRequestId[requestId] = nil
        supersededByRequestId[requestId] = nil
        guard latestRequestBySession[pending.sessionId] == requestId else { return [:] }
        let suggestions = (call.payload["suggestions"] as? [[String: Any]]) ?? []
        bridgeRouter?.send(event: "omniboxSuggestions", data: [
            "sessionId": pending.sessionId,
            "extensionId": extensionId,
            "suggestions": suggestions,
            "defaultSuggestion": defaultSuggestions[extensionId] ?? ""
        ])
        return [:]
    }

    // MARK: - Helpers

    func tracks(requestId: String) -> Bool {
        pendingByRequestId[requestId] != nil || supersededByRequestId[requestId] != nil
    }

    /// Resolve "<keyword> <text>" to the owning extension. Requires a space after the keyword (Chrome
    /// activates omnibox mode only once the keyword token is committed with a trailing space).
    private func owner(forQuery query: String) -> (id: String, text: String)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else { return nil }
        let keyword = String(trimmed[..<spaceIndex])
        let text = String(trimmed[trimmed.index(after: spaceIndex)...])
        guard let id = resolveKeywordOwner(keyword) else { return nil }
        return (id, text)
    }
}

/// The gap side of chrome.omnibox. The app-wide gap router keeps one handler per action, while each
/// window owns its address-bar sessions: replies go to the window that issued the request.
@MainActor
final class OmniboxGapRelay: GapHandler {
    static let shared = OmniboxGapRelay()

    let gapActions: Set<String> = ["omnibox.sendSuggestions", "omnibox.setDefaultSuggestion"]
    private let windowHandlers = NSHashTable<OmniboxBridgeHandler>.weakObjects()

    func add(_ handler: OmniboxBridgeHandler) {
        windowHandlers.add(handler)
    }

    func handle(_ call: GapCall) async -> Any? {
        let handlers = windowHandlers.allObjects
        if call.action == "omnibox.setDefaultSuggestion" {
            handlers.forEach { $0.setDefaultSuggestion(call) }
            return [:]
        }
        let requestId = call.string("requestId") ?? ""
        guard let owner = handlers.first(where: { $0.tracks(requestId: requestId) }) else {
            return BridgeError("Unknown or unauthorized omnibox request")
        }
        return owner.sendSuggestions(call)
    }
}
