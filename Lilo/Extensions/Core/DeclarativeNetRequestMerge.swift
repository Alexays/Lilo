import Foundation
import ObjectiveC.runtime

/// WebKit translates each declarativeNetRequest rule into its own content blocker rule, one per domain of `allowAllRequests`
/// and `initiatorDomains` too, and reads the actions of every matching rule on each request before checking their
/// conditions: thousands of `.*` exceptions differing only by their page cost every request of the page.
/// The translation is merged before WebKit compiles it, so such rules become one with the union of their pages.
enum DeclarativeNetRequestMerge {
    /// Lists that match when any of their entries does, so two rules differing only by one are one rule with both entries.
    private static let anyOfKeys = ["if-top-url", "if-frame-url"]
    /// Actions whose outcome does not depend on which rule of a run of them matched, so their rules may move within the run.
    private static let orderFreeActions: Set<String> = ["block", "ignore-following-rules"]

    /// Wraps `+[_WKWebExtensionDeclarativeNetRequestTranslator translateRules:errorStrings:]`, which WebKit calls off the
    /// main thread before each compile. WebKit hashes its output to reuse the compiled list, so a merged one recompiles once.
    static let install: Void = {
        let selector = NSSelectorFromString("translateRules:errorStrings:")
        guard let translator = NSClassFromString("_WKWebExtensionDeclarativeNetRequestTranslator"),
              let method = class_getClassMethod(translator, selector) else { return }
        typealias Translate = @convention(c) (AnyObject, Selector, NSDictionary, UnsafeMutableRawPointer?) -> NSArray?
        let original = unsafeBitCast(method_getImplementation(method), to: Translate.self)
        let translate: @convention(block) (AnyObject, NSDictionary, UnsafeMutableRawPointer?) -> NSArray? = { translator, rules, errors in
            original(translator, selector, rules, errors).map(merged)
        }
        method_setImplementation(method, imp_implementationWithBlock(translate))
    }()

    /// WebKit content blocker rules, in order, with the rules of a run of one order-free action that differ only by one
    /// `anyOfKeys` list merged into the first of them.
    static func merged(_ rules: NSArray) -> NSArray {
        let out = NSMutableArray(capacity: rules.count)
        var runAction: NSDictionary?
        var slots: [String: NSMutableArray] = [:]
        for case let rule as NSDictionary in rules {
            let action = rule["action"] as? NSDictionary
            if action != runAction {
                runAction = action
                slots = [:]
            }
            guard rule.count == 2, let action, let trigger = rule["trigger"] as? NSDictionary,
                  let type = action["type"] as? String, orderFreeActions.contains(type) else {
                out.add(rule)
                continue
            }
            let lists = anyOfKeys.filter { trigger[$0] != nil }
            guard lists.count == 1, let listKey = lists.first, let list = trigger[listKey] as? [Any],
                  let rest = trigger.mutableCopy() as? NSMutableDictionary else {
                out.add(rule)
                continue
            }
            rest.removeObject(forKey: listKey)
            guard let restJSON = try? JSONSerialization.data(withJSONObject: rest, options: .sortedKeys),
                  let restKey = String(bytes: restJSON, encoding: .utf8) else {
                out.add(rule)
                continue
            }
            let key = listKey + restKey
            if let entries = slots[key] {
                entries.addObjects(from: list)
                continue
            }
            let entries = NSMutableArray(array: list)
            rest[listKey] = entries
            slots[key] = entries
            out.add(["action": action, "trigger": rest])
        }
        return out
    }
}
