import Foundation
import WebKit

/// chrome.declarativeNetRequest's disabled static rules, which WebKit lacks: they turn inert in the
/// extension's ruleset files (ExtensionBackgroundPreparer), off the main thread and one call at a time.
/// Also remembers the session rules each context set this run, which WebKit holds as dynamic ones (dnr-rules.ts).
@MainActor
final class DeclarativeNetRequestBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "declarativeNetRequest.getDisabledRuleIds",
        "declarativeNetRequest.updateStaticRules",
        "declarativeNetRequest.sessionRules"
    ]

    private var lastCall: Task<Void, Never>?
    /// In memory only, as Chrome's session rules: a relaunch or a reloaded context starts unclaimed, with no id of its own.
    private let claimedSessionRules = NSHashTable<WKWebExtensionContext>.weakObjects()
    private let sessionRuleIds = NSMapTable<WKWebExtensionContext, NSArray>.weakToStrongObjects()

    func handle(_ call: GapCall) async -> Any? {
        if call.action == "declarativeNetRequest.sessionRules" {
            guard let context = call.context else { return BridgeError("Extension not found") }
            if call.bool("claim") {
                claimedSessionRules.add(context)
                sessionRuleIds.removeObject(forKey: context)
            } else if let ids = call.payload["ids"] as? [Int] {
                sessionRuleIds.setObject(ids as NSArray, forKey: context)
            }
            return ["claimed": claimedSessionRules.contains(context), "ids": sessionRuleIds.object(forKey: context) ?? []]
        }
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
