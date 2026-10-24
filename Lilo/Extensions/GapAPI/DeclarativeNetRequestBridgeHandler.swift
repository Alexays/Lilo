import Foundation

/// chrome.declarativeNetRequest's disabled static rules, which WebKit lacks: they turn inert in the
/// extension's ruleset files (ExtensionBackgroundPreparer), off the main thread and one call at a time.
@MainActor
final class DeclarativeNetRequestBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "declarativeNetRequest.getDisabledRuleIds",
        "declarativeNetRequest.updateStaticRules"
    ]

    private var lastCall: Task<Void, Never>?

    func handle(_ call: GapCall) async -> Any? {
        guard let rulesetId = call.string("rulesetId") else { return BridgeError("rulesetId must be a string") }
        guard let context = call.context,
              let sourcePath = call.registry.loadedExtensions.first(where: { $0.id == call.extensionId })?.sourcePath else {
            return BridgeError("Extension not found")
        }
        let extensionURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let rulesets = ExtensionBackgroundPreparer.staticRulesets(extensionURL: extensionURL, manifest: context.webExtension.manifest)
        if call.action == "declarativeNetRequest.getDisabledRuleIds" {
            return await queued {
                try ExtensionBackgroundPreparer.disabledStaticRuleIds(extensionURL: extensionURL, rulesets: rulesets, rulesetId: rulesetId)
            }
        }
        guard let disable = call.payload["disableRuleIds"] as? [Int], let enable = call.payload["enableRuleIds"] as? [Int] else {
            return BridgeError("disableRuleIds and enableRuleIds must be arrays of integers")
        }
        return await queued {
            try ExtensionBackgroundPreparer.updateStaticRules(
                extensionURL: extensionURL, rulesets: rulesets, rulesetId: rulesetId, disable: disable, enable: enable
            )
        }
    }

    /// Runs `work` off the main thread, a ruleset file being up to tens of megabytes, once the calls before it are done.
    private func queued<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Any? {
        let previous = lastCall
        let task = Task.detached { () -> Result<T, BridgeError> in
            await previous?.value
            do {
                return .success(try work())
            } catch {
                return .failure(BridgeError(error.localizedDescription))
            }
        }
        lastCall = Task { _ = await task.value }
        switch await task.value {
        case .success(let value): return value
        case .failure(let error): return error
        }
    }
}
