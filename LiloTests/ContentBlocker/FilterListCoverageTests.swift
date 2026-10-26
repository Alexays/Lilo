import XCTest
@testable import Lilo

/// `make blocker-coverage`: fetches the default lists, converts each rule on its own, and writes how many of each kind converted
/// and why the others were skipped to the path in LILO_BLOCKER_COVERAGE. Skipped otherwise: it needs the network.
final class FilterListCoverageTests: XCTestCase {
    func testReportCoverageOfTheDefaultLists() async throws {
        guard let out = ProcessInfo.processInfo.environment["LILO_BLOCKER_COVERAGE"] else {
            throw XCTSkip("Run by make blocker-coverage")
        }
        let sources = FilterListService.sources(for: .init(languages: Locale.preferredLanguages))
        var text = ""
        for url in sources {
            let (data, _) = try await URLSession.shared.data(from: url)
            let list = String(decoding: data, as: UTF8.self)
            // As FilterListService assembles them: only uBO's own lists are trusted.
            text += url.absoluteString.hasPrefix(FilterListService.trustedListPrefix) ? "!#trusted on\n\(list)\n!#trusted off\n" : list + "\n"
        }
        let report = "lists: " + sources.map(\.lastPathComponent).joined(separator: " ") + "\n" + Self.report(text)
        try report.write(toFile: out, atomically: true, encoding: .utf8)
    }

    private static let networkOptions: Set<String> = [
        "script", "image", "stylesheet", "css", "font", "media", "xmlhttprequest", "xhr", "websocket", "ping", "beacon",
        "subdocument", "frame", "document", "doc", "popup", "other", "object", "third-party", "3p", "first-party", "1p",
        "strict3p", "match-case", "important", "all", "_", "domain", "from", "reason"
    ]
    /// Options that make a network rule a kind of its own.
    private static let networkKinds = [
        "redirect-rule", "redirect", "rewrite", "removeparam", "csp", "header", "permissions", "replace", "urlskip", "uritransform",
        "urltransform", "denyallow", "to", "method", "badfilter", "generichide", "ghide", "elemhide", "ehide", "specifichide",
        "shide", "cname", "inline-script", "inline-font", "empty", "mp4"
    ]

    private static func report(_ text: String) -> String {
        var converted: [String: Int] = [:]
        var reasons: [String: [String: Int]] = [:]
        var examples: [String: String] = [:]
        var conditions: [Bool] = []
        var trusted = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#") {
                // The converter's own reading of `!#if` and `!#trusted`.
                if line.hasPrefix("!#if ") {
                    let token = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    let negated = token.hasPrefix("!")
                    conditions.append((negated ? token.dropFirst() : Substring(token)) == "env_safari" ? !negated : negated)
                } else if line == "!#else", !conditions.isEmpty {
                    conditions[conditions.count - 1].toggle()
                } else if line == "!#endif" {
                    _ = conditions.popLast()
                } else if line == "!#trusted on" || line == "!#trusted off" {
                    trusted = line == "!#trusted on"
                }
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !conditions.contains(false) else { continue }
            let kind = kind(of: line)
            let out = FilterListConverter.convert(trusted ? "!#trusted on\n" + line : line)
            let produced = !(out.blocks.isEmpty && out.exceptions.isEmpty && out.important.isEmpty && out.cosmetic.isEmpty
                && out.domainCosmetic.isEmpty && out.cosmeticExceptions.isEmpty && out.genericHide.isEmpty && out.scriptlets.isEmpty
                && out.scriptletExceptions.isEmpty && out.procedural.isEmpty && out.proceduralExceptions.isEmpty && out.extensionRules.isEmpty)
            // A generic `#@#selector` and a `$badfilter` only act on other rules.
            if produced || (line.hasPrefix("#@#") && !line.contains("+js(")) || options(of: line).contains("badfilter") {
                converted[kind, default: 0] += 1
            } else {
                let why = reason(line, kind: kind, trusted: trusted)
                reasons[kind, default: [:]][why, default: 0] += 1
                if examples[kind + why] == nil { examples[kind + why] = line }
            }
        }
        let skipped = reasons.mapValues { $0.values.reduce(0, +) }
        let total = converted.values.reduce(0, +) + skipped.values.reduce(0, +)
        var lines = ["\(total) rules, \(converted.values.reduce(0, +)) converted, \(skipped.values.reduce(0, +)) skipped"]
        for kind in Set(converted.keys).union(skipped.keys).sorted(by: { converted[$0, default: 0] + skipped[$0, default: 0] > converted[$1, default: 0] + skipped[$1, default: 0] }) {
            let (c, s) = (converted[kind, default: 0], skipped[kind, default: 0])
            lines.append(kind.padding(toLength: 34, withPad: " ", startingAt: 0) + "\(c + s) total, \(c) converted, \(s) skipped")
            for (why, count) in (reasons[kind] ?? [:]).sorted(by: { $0.value > $1.value }).prefix(12) {
                lines.append("    \(count)  \(why)    e.g. \(examples[kind + why]!.prefix(100))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func kind(of line: String) -> String {
        if line.contains("#@#+js(") { return "scriptlet exception" }
        if line.contains("##+js(") { return "scriptlet" }
        if line.contains("#@#") || line.contains("#@?#") { return "cosmetic exception" }
        if line.contains("##^") { return "html filter" }
        if line.contains("#$#") || line.contains("#$?#") || line.contains("#%#") { return "adguard extension" }
        if let marker = line.range(of: "#?#") ?? line.range(of: "##") {
            let selector = line[marker.upperBound...]
            let tokens = FilterListConverter.proceduralSupportedTokens + FilterListConverter.proceduralUnsupportedTokens + [":-abp-"]
            if selector.hasSuffix(")"), selector.contains(":style("), !selector.contains(":has-text(") { return "style" }
            if tokens.contains(where: { selector.contains($0) }) { return "procedural" }
            if selector.contains("{") { return "css injection" }
            return line[..<marker.lowerBound].isEmpty ? "cosmetic generic" : "cosmetic specific"
        }
        let prefix = line.hasPrefix("@@") ? "network exception" : "network"
        let options = options(of: line)
        if let special = networkKinds.first(where: { options.contains($0) }) { return prefix + " $" + special }
        return prefix
    }

    private static func options(of line: String) -> [String] {
        let body = line.hasPrefix("@@") ? line.dropFirst(2) : Substring(line)
        let start = body.hasPrefix("/") ? body.range(of: "/$", options: .backwards)?.upperBound
            : body.firstIndex(of: "$").map { body.index(after: $0) }
        guard let start else { return [] }
        return body[start...].split(separator: ",").map { option in
            String(option.drop { $0 == "~" }.prefix { $0 != "=" })
        }
    }

    /// Why a rule was skipped, from the first thing in it the converter cannot express.
    private static func reason(_ line: String, kind: String, trusted: Bool) -> String {
        if kind.hasPrefix("network") {
            let body = line.hasPrefix("@@") ? line.dropFirst(2) : Substring(line)
            if let unknown = options(of: line).first(where: { !networkOptions.contains($0) }) { return "option $" + unknown }
            if let domain = body.range(of: "domain=") ?? body.range(of: "from=") {
                let entries = body[domain.upperBound...].prefix { $0 != "," }.split(separator: "|")
                if entries.contains(where: { $0.contains("/") }) { return "regex domain" }
                if entries.contains(where: { $0.hasSuffix(".*") }) { return "entity domain (example.*)" }
                if entries.contains(where: { $0.hasPrefix("~") }), entries.contains(where: { !$0.hasPrefix("~") }) { return "domain and ~domain" }
            }
            let pattern = body.prefix { $0 != "$" }
            if kind == "network", !pattern.hasPrefix("|"), pattern.trimmingCharacters(in: ["*"]).contains("*") { return "unanchored inner wildcard" }
            if body.hasPrefix("/") { return "regex WebKit cannot express" }
            if !body.allSatisfy(\.isASCII) { return "non-ASCII" }
            return "other"
        }
        if kind.hasPrefix("scriptlet") {
            guard let open = line.range(of: "+js(") else { return "other" }
            var name = FilterListConverter.parseScriptletArgs(String(line[open.upperBound...].dropLast())).first ?? ""
            if name.hasSuffix(".js") { name.removeLast(3) }
            let canonical = FilterListConverter.scriptletAliases[name] ?? name
            if !FilterListConverter.supportedScriptlets.contains(canonical), !canonical.isEmpty { return "scriptlet " + canonical }
            if line.hasPrefix("#@#") || line.hasPrefix("##") { return "generic" }
            return trusted ? "other" : "trusted scriptlet outside uBO's lists"
        }
        let selector = (line.range(of: "#@#") ?? line.range(of: "#?#") ?? line.range(of: "##")).map { line[$0.upperBound...] } ?? ""
        for token in FilterListConverter.proceduralUnsupportedTokens + [":-abp-"] where selector.contains(token) { return "operator " + token }
        if line.hasPrefix("##") || line.hasPrefix("#?#") || line.hasPrefix("#@#") { return "generic " + kind }
        return kind == "cosmetic exception" ? "procedural operator in an exception" : "other"
    }
}
