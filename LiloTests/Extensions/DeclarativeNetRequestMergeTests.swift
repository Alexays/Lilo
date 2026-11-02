import ObjectiveC.runtime
import WebKit
import XCTest
@testable import Lilo

final class DeclarativeNetRequestMergeTests: XCTestCase {
    func testWebKitsTranslationOfSitewideExceptionsIsOneRule() throws {
        _ = DeclarativeNetRequestMerge.install
        _ = WKWebView.self
        let translator: AnyClass = try XCTUnwrap(NSClassFromString("_WKWebExtensionDeclarativeNetRequestTranslator"))
        let selector = NSSelectorFromString("translateRules:errorStrings:")
        let method = try XCTUnwrap(class_getClassMethod(translator, selector))
        typealias Translate = @convention(c) (AnyObject, Selector, NSDictionary, UnsafeMutableRawPointer?) -> NSArray?
        let translate = unsafeBitCast(method_getImplementation(method), to: Translate.self)
        let rules = ["one.example", "two.example", "three.example"].enumerated().map { index, domain in
            ["id": index + 1, "priority": index + 1, "action": ["type": "allowAllRequests"],
             "condition": ["urlFilter": "||\(domain)^", "resourceTypes": ["main_frame"]]] as [String: Any]
        } + [["id": 10, "action": ["type": "block"], "condition": ["urlFilter": "||ads.example^"]]]

        let translated = try XCTUnwrap(translate(translator as AnyObject, selector, ["ruleset": rules], nil) as? [[String: Any]])

        let exceptions = translated.filter { ($0["action"] as? [String: Any])?["type"] as? String == "ignore-following-rules" }
        XCTAssertEqual(exceptions.count, 1)
        let pages = try XCTUnwrap((exceptions.first?["trigger"] as? [String: Any])?["if-top-url"] as? [String])
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages.allSatisfy { $0.contains("example") })
        XCTAssertEqual(translated.count, 2)
    }

    func testMergesOnlyWithinARunOfOneOrderFreeAction() throws {
        let block = ["type": "block"], allow = ["type": "ignore-following-rules"], headers = ["type": "modify-headers"]
        let rules: [[String: Any]] = [
            ["action": allow, "trigger": ["url-filter": ".*", "if-top-url": ["a"]]],
            ["action": allow, "trigger": ["url-filter": ".*", "if-top-url": ["b"]]],
            ["action": allow, "trigger": ["url-filter": ".*", "if-frame-url": ["c"], "load-context": ["child-frame"]]],
            ["action": block, "trigger": ["url-filter": "x", "if-frame-url": ["d"]]],
            ["action": block, "trigger": ["url-filter": "x", "unless-frame-url": ["e"]]],
            ["action": block, "trigger": ["url-filter": "y", "if-frame-url": ["f"]]],
            ["action": block, "trigger": ["url-filter": "x", "if-frame-url": ["g"]]],
            ["action": allow, "trigger": ["url-filter": ".*", "if-top-url": ["h"]]],
            ["action": headers, "trigger": ["url-filter": ".*", "if-top-url": ["i"]]],
            ["action": headers, "trigger": ["url-filter": ".*", "if-top-url": ["j"]]],
        ]

        let merged = try XCTUnwrap(DeclarativeNetRequestMerge.merged(rules as NSArray) as? [[String: Any]])

        let lists = merged.map { rule -> [String] in
            let trigger = rule["trigger"] as? [String: Any] ?? [:]
            return (trigger["if-top-url"] ?? trigger["if-frame-url"] ?? trigger["unless-frame-url"]) as? [String] ?? []
        }
        XCTAssertEqual(lists, [["a", "b"], ["c"], ["d", "g"], ["e"], ["f"], ["h"], ["i"], ["j"]])
    }
}
