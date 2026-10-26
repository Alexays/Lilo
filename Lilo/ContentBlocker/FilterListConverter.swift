import Foundation

/// Converts ABP/EasyList syntax to WKContentRuleList rules; a modifier or regex WebKit cannot express exactly is skipped, never approximated.
/// Exceptions are returned apart so the caller emits them after every block: `ignore-previous-rules` only beats earlier rules.
enum FilterListConverter {
    struct DomainCosmetic: Equatable {
        let domains: [String]
        let selector: String
    }

    struct ScriptletInjection: Equatable {
        let domains: [String]
        let name: String
        let args: [String]
    }

    /// Procedural pseudo-classes implemented in ProceduralCosmetics.js (as `:name(` prefixes).
    static let proceduralSupportedTokens: [String] = [
        ":has-text(", ":contains(", ":-abp-contains(", ":style(", ":upward(", ":nth-ancestor(",
        ":xpath(", ":remove(", ":matches-css(", ":matches-css-before(", ":matches-css-after(",
        ":remove-attr(", ":remove-class(", ":matches-attr(", ":matches-path(", ":others(", ":-abp-properties("
    ]

    /// Extended pseudo-classes we do NOT implement: a selector using one is skipped entirely.
    static let proceduralUnsupportedTokens: [String] = [
        ":min-text-length(", ":watch-attr(", ":matches-media(", ":if(", ":if-not("
    ]

    struct ConversionResult {
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        /// `$important` blocks, which no exception may override.
        var important: [[String: Any]] = []
        var cosmetic: [String] = []
        var domainCosmetic: [DomainCosmetic] = []
        /// `domains#@#selector` exceptions; the domain-less ones are already taken out of `cosmetic`.
        var cosmeticExceptions: [DomainCosmetic] = []
        /// Hosts a `@@||host^$generichide` (or `ghide`, `elemhide`, `ehide`) exception exempts from
        /// generic cosmetics.
        var genericHide: [String] = []
        var scriptlets: [ScriptletInjection] = []
        /// `domains#@#+js(...)` exceptions and excluded hosts; an empty name excepts every scriptlet.
        var scriptletExceptions: [ScriptletInjection] = []
        var procedural: [DomainCosmetic] = []
        var proceduralExceptions: [DomainCosmetic] = []
        /// declarativeNetRequest rules (without ids) for the built-in extension; see `declarativeRule`.
        var extensionRules: [[String: Any]] = []
    }

    /// uBO scriptlet name aliases, mapped to the canonical name implemented in Scriptlets.js.
    static let scriptletAliases: [String: String] = [
        "json-prune.js": "json-prune", "jp": "json-prune",
        "set": "set-constant", "set-constant.js": "set-constant",
        "aopr": "abort-on-property-read", "abort-on-property-read.js": "abort-on-property-read",
        "aopw": "abort-on-property-write", "abort-on-property-write.js": "abort-on-property-write",
        "acs": "abort-current-script", "acis": "abort-current-script",
        "abort-current-inline-script": "abort-current-script", "abort-current-inline-script.js": "abort-current-script",
        "nostif": "no-setTimeout-if", "setTimeout-defuser": "no-setTimeout-if", "std.js": "no-setTimeout-if",
        "nosiif": "no-setInterval-if", "setInterval-defuser": "no-setInterval-if", "sid.js": "no-setInterval-if",
        "prevent-fetch": "no-fetch-if", "no-fetch-if.js": "no-fetch-if",
        "prevent-xhr": "no-xhr-if", "no-xhr-if.js": "no-xhr-if",
        "nowoif": "no-window-open-if", "window.open-defuser": "no-window-open-if", "nowoif.js": "no-window-open-if",
        "aeld": "prevent-addEventListener", "addEventListener-defuser": "prevent-addEventListener", "aeld.js": "prevent-addEventListener",
        "trusted-rpfr": "trusted-replace-fetch-response",
        "rpnt": "replace-node-text", "trusted-rpnt": "replace-node-text", "trusted-replace-node-text": "replace-node-text",
        "rmnt": "remove-node-text",
        "nano-stb": "adjust-setTimeout", "nano-setTimeout-booster": "adjust-setTimeout",
        "nano-sib": "adjust-setInterval", "nano-setInterval-booster": "adjust-setInterval",
        "aost": "abort-on-stack-trace", "ra": "remove-attr", "rc": "remove-class", "cookie-remover": "remove-cookie",
        "prevent-eval-if": "noeval-if", "trusted-set": "trusted-set-constant",
        "nobab": "bab-defuser", "nofab": "fuckadblock-defuser", "norafif": "no-requestAnimationFrame-if",
        "prevent-requestAnimationFrame": "no-requestAnimationFrame-if", "prevent-window-open": "no-window-open-if"
    ]

    /// Canonical scriptlet names implemented in Scriptlets.js. A `##+js` filter naming
    /// anything outside this set is skipped.
    static let supportedScriptlets: Set<String> = [
        "json-prune", "json-prune-fetch-response", "json-prune-xhr-response", "set-constant",
        "abort-on-property-read", "abort-on-property-write", "abort-current-script",
        "no-setTimeout-if", "no-setInterval-if", "no-fetch-if", "no-xhr-if",
        "no-window-open-if", "prevent-addEventListener",
        "trusted-replace-xhr-response", "trusted-replace-fetch-response",
        "set-cookie", "trusted-set-cookie", "set-local-storage-item", "trusted-set-local-storage-item",
        "trusted-click-element", "replace-node-text", "remove-node-text", "adjust-setTimeout",
        "trusted-prevent-dom-bypass", "trusted-edit-inbound-object", "adjust-setInterval", "abort-on-stack-trace",
        "remove-attr", "remove-class", "remove-cookie", "set-session-storage-item", "trusted-set-session-storage-item",
        "nowebrtc", "noeval", "noeval-if", "trusted-replace-argument", "trusted-replace-outbound-text",
        "json-edit", "trusted-json-edit", "json-edit-fetch-response", "trusted-json-edit-fetch-response",
        "json-edit-xhr-response", "trusted-json-edit-xhr-response", "jsonl-edit-xhr-response", "trusted-prevent-fetch", "trusted-prevent-xhr",
        "trusted-set-constant", "href-sanitizer", "edit-object-on-setter", "trusted-suppress-native-method",
        "prevent-innerHTML", "xml-prune", "m3u-prune", "trusted-create-html", "popads-dummy", "bab-defuser",
        "fuckadblock-defuser", "refresh-defuser", "no-requestAnimationFrame-if", "set-cookie-reload",
        "trusted-set-cookie-reload", "set-attr", "trusted-set-attr", "trusted-override-element-method", "spoof-css",
        "disable-newtab-links"
    ]

    static func convert(_ text: String) -> ConversionResult {
        var result = ConversionResult()
        // Native UTF-8 lines: Foundation's line enumeration hands out NSString-backed lines, and every
        // later character access on them goes through CoreFoundation.
        var text = text
        text.makeContiguousUTF8()
        let lines = text.split(whereSeparator: \.isNewline).map { line -> Substring in
            var line = line
            while let first = line.first, first == " " || first == "\t" { line.removeFirst() }
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            return line
        }
        // A `$badfilter` rule disables the rule it repeats without that option, whichever list carries it.
        var badfilters = Set<String>()
        if text.contains("badfilter") {
            for trimmed in lines where trimmed.contains("badfilter") {
                guard !trimmed.hasPrefix("!"), let dollar = trimmed.firstIndex(of: "$") else { continue }
                let options = trimmed[trimmed.index(after: dollar)...].split(separator: ",")
                let kept = options.filter { $0 != "badfilter" }
                guard kept.count < options.count else { continue }
                let pattern = trimmed[..<dollar]
                badfilters.insert(kept.isEmpty ? String(pattern) : String(pattern) + "$" + kept.joined(separator: ","))
            }
        }
        func append(_ rule: NetworkRule) {
            if rule.isException {
                result.exceptions.append(rule.dict)
            } else if rule.isImportant {
                result.important.append(rule.dict)
            } else {
                result.blocks.append(rule.dict)
            }
        }
        var genericExceptions = Set<String>()
        // `!#if` blocks, outermost first: Lilo is a Safari-like WebKit browser with no other uBO capability.
        var conditions: [Bool] = []
        // Set by the `!#trusted on` and `!#trusted off` lines FilterListService wraps uBO's own lists in.
        var trusted = false
        for line in lines {
            var trimmed = String(line)
            // ABP's spelling of the native `:has()`.
            if trimmed.contains(":-abp-has(") { trimmed = trimmed.replacingOccurrences(of: ":-abp-has(", with: ":has(") }
            if trimmed.hasPrefix("!#") {
                if trimmed.hasPrefix("!#if ") {
                    let token = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    let negated = token.hasPrefix("!")
                    conditions.append((negated ? token.dropFirst() : Substring(token)) == "env_safari" ? !negated : negated)
                } else if trimmed == "!#else", !conditions.isEmpty {
                    conditions[conditions.count - 1].toggle()
                } else if trimmed == "!#endif" {
                    _ = conditions.popLast()
                } else if trimmed == "!#trusted on" || trimmed == "!#trusted off" {
                    trusted = trimmed == "!#trusted on"
                }
                continue
            }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !conditions.contains(false) else { continue }
            if !badfilters.isEmpty, badfilters.contains(trimmed) { continue }
            // Every cosmetic marker contains '#', so a line without one can only be a network rule.
            guard trimmed.contains("#") else {
                if let hosts = genericHideHosts(trimmed) {
                    result.genericHide += hosts
                    continue
                }
                guard !trimmed.hasPrefix("[") else { continue }
                if let rule = declarativeRule(trimmed) {
                    result.extensionRules.append(rule)
                    // An exception also holds among the content rules.
                    guard trimmed.hasPrefix("@@") else { continue }
                }
                networkRules(trimmed).forEach(append)
                continue
            }
            guard let (domainPart, selector, isException) = cosmeticParts(trimmed) else {
                convertLine(trimmed).forEach(append)
                continue
            }
            // uBO compiles an excluded host as an exception there; an exception's own exclusions are dropped, which only
            // hides less.
            guard let (included, excluded) = ruleDomains(domainPart) else { continue }
            if selector.hasPrefix("+js(") {
                guard let (name, args) = scriptlet(selector, trusted: trusted || isException) else { continue }
                if isException {
                    if !included.isEmpty { result.scriptletExceptions.append(.init(domains: included, name: name, args: args)) }
                } else if !included.isEmpty {
                    result.scriptlets.append(.init(domains: included, name: name, args: args))
                    if !excluded.isEmpty { result.scriptletExceptions.append(.init(domains: excluded, name: name, args: args)) }
                }
                continue
            }
            guard let (css, isProcedural) = cosmeticSelector(selector) else { continue }
            // Generic `:style()` and procedural rules are not supported.
            guard !included.isEmpty || !(isProcedural || css.contains("{")) else { continue }
            if isException {
                if included.isEmpty {
                    genericExceptions.insert(css)
                } else if isProcedural {
                    result.proceduralExceptions.append(.init(domains: included, selector: css))
                } else {
                    result.cosmeticExceptions.append(.init(domains: included, selector: css))
                }
            } else if isProcedural {
                result.procedural.append(.init(domains: included, selector: css))
                if !excluded.isEmpty { result.proceduralExceptions.append(.init(domains: excluded, selector: css)) }
            } else {
                if included.isEmpty {
                    result.cosmetic.append(css)
                } else {
                    result.domainCosmetic.append(.init(domains: included, selector: css))
                }
                if !excluded.isEmpty { result.cosmeticExceptions.append(.init(domains: excluded, selector: css)) }
            }
        }
        if !genericExceptions.isEmpty {
            result.cosmetic.removeAll { genericExceptions.contains($0) }
        }
        return result
    }

    // MARK: - Cosmetic

    /// ABP extended/procedural pseudo-classes that aren't plain CSS.
    private static let extendedCosmeticTokens = [
        ":-abp-", ":style(", ":has-text(", ":matches-css", ":xpath(", ":upward(",
        ":nth-ancestor(", ":remove(", ":watch-attr(", ":min-text-length(", ":contains(", ":others(",
        ":remove-attr(", ":remove-class(", ":matches-attr(", ":matches-path("
    ]

    /// `domains##selector`, `#@#` for an exception, and uBO's procedural spellings `#?#` and `#@?#`, split at the first marker.
    /// nil for any other line (AdGuard's `#$#` and `#%#` included).
    private static func cosmeticParts(_ line: String) -> (domains: Substring, selector: String, isException: Bool)? {
        guard !line.hasPrefix("["), var index = line.firstIndex(of: "#") else { return nil }
        while true {
            let rest = line[index...]
            for (marker, isException) in [("##", false), ("#@#", true), ("#?#", false), ("#@?#", true)] where rest.hasPrefix(marker) {
                return (line[..<index], rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces), isException)
            }
            guard let next = line[line.index(after: index)...].firstIndex(of: "#") else { return nil }
            index = next
        }
    }

    /// A cosmetic selector as the tables hold it, and whether it is procedural; nil for what cannot be applied exactly. A plain
    /// selector ending in `:style(...)` becomes the CSS rule `selector{declarations}`, which the site style sheet takes as is.
    private static func cosmeticSelector(_ selector: String) -> (selector: String, isProcedural: Bool)? {
        // `^` starts an HTML filter, which edits the response before parsing.
        guard !selector.isEmpty, !selector.hasPrefix("+"), !selector.hasPrefix("^") else { return nil }
        guard selector.contains(":"), extendedCosmeticTokens.contains(where: { selector.contains($0) }) else {
            return selector.contains("{") ? nil : (selector, false)
        }
        if selector.hasSuffix(")"), let style = selector.range(of: ":style(", options: .backwards) {
            let css = selector[..<style.lowerBound].trimmingCharacters(in: .whitespaces)
            let declarations = selector[style.upperBound..<selector.index(before: selector.endIndex)].trimmingCharacters(in: .whitespaces)
            // Declarations that could close the rule, or fetch something, stay out of the style sheet.
            if !css.isEmpty, !declarations.isEmpty, !css.contains("{"), !extendedCosmeticTokens.contains(where: { css.contains($0) }),
               !["{", "}", "\\", "url(", "/*", "@import", "image-set("].contains(where: { declarations.contains($0) }) {
                return (css + "{" + declarations + "}", false)
            }
        }
        guard proceduralSupportedTokens.contains(where: { selector.contains($0) }),
              !proceduralUnsupportedTokens.contains(where: { selector.contains($0) }) else { return nil }
        return (selector, true)
    }

    /// The sites a `@@||host^$generichide` exception (or `ghide`, `elemhide`, `ehide`) names, or a `@@*$ghide,domain=a|b` one does.
    private static func genericHideHosts(_ line: String) -> [String]? {
        guard line.hasPrefix("@@"), let dollar = line.firstIndex(of: "$") else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",")
        let others = options.filter { !["generichide", "ghide", "elemhide", "ehide"].contains($0) }
        guard others.count < options.count else { return nil }
        var host = line[line.index(line.startIndex, offsetBy: 2)..<dollar]
        if host.isEmpty || host == "*" {
            guard others.count == 1, let domains = others[0].wholeMatch(of: #/domain=([a-zA-Z0-9.*|-]+)/#)?.1 else { return nil }
            return domains.split(separator: "|").map { $0.lowercased() }
        }
        guard host.hasPrefix("||") else { return nil }
        host = host.dropFirst(2)
        if host.hasSuffix("^") { host = host.dropLast() }
        // `name.*` is uBO's entity: the site under any public suffix, as the site table keys it.
        guard !host.isEmpty, !host.dropLast(host.hasSuffix(".*") ? 2 : 0).contains(where: { "/*^|".contains($0) }),
              let ascii = asciiHost(host.lowercased()) else { return nil }
        return [ascii]
    }

    /// The host as pages report it: an internationalized name in its punycode form. nil when it cannot be encoded.
    private static func asciiHost(_ host: String) -> String? {
        host.allSatisfy(\.isASCII) ? host : URLComponents(string: "http://" + host)?.encodedHost
    }

    /// A rule's lowercased domains, those it names and the `~` ones it excludes. uBO's `host>>` applies to the host only, and `*`
    /// to every site. nil when a uBO `/regex/` entry, which exact-host tables cannot apply, or a host that cannot be encoded
    /// would leave the rule wider.
    private static func ruleDomains(_ domainPart: Substring) -> (included: [String], excluded: [String])? {
        var included: [String] = []
        var excluded: [String] = []
        var namesRegex = false
        var parts = domainPart.split(separator: ",", omittingEmptySubsequences: false)[...]
        while var host = parts.popFirst()?.trimmingCharacters(in: .whitespaces).lowercased() {
            let isExcluded = host.hasPrefix("~")
            if isExcluded { host.removeFirst() }
            if host.hasPrefix("/") {
                // A regex's own commas don't separate domains.
                while host.count < 2 || !host.hasSuffix("/"), let next = parts.popFirst() { host += "," + next }
                guard !isExcluded else { return nil }
                namesRegex = true
                continue
            }
            if host.hasSuffix(">>") { host.removeLast(2) }
            guard !host.isEmpty, host != "*" else { continue }
            guard let ascii = asciiHost(host) else { return nil }
            host = ascii
            if isExcluded {
                excluded.append(host)
            } else {
                included.append(host)
            }
        }
        return namesRegex && included.isEmpty ? nil : (included, excluded)
    }

    /// Split the inside of `##+js(...)` into arguments, as uBO does: one wrapped in ', " or ` is taken
    /// between its quotes, commas included; any other ends at an unescaped comma and is trimmed. A `\`
    /// before the closing character is dropped. The first element is the scriptlet name; the rest are its args.
    static func parseScriptletArgs(_ inside: String) -> [String] {
        let chars = Array(inside)
        func read(from start: Int, until stop: Character) -> (text: String, end: Int) {
            var text = ""
            var i = start
            while i < chars.count, chars[i] != stop {
                if chars[i] == "\\", i + 1 < chars.count {
                    if chars[i + 1] != stop { text.append("\\") }
                    text.append(chars[i + 1])
                    i += 2
                } else {
                    text.append(chars[i])
                    i += 1
                }
            }
            return (text, i)
        }
        var args: [String] = []
        var i = 0
        while true {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            // A quote only opens a quoted argument when its closing quote ends the argument.
            if i < chars.count, "'\"`".contains(chars[i]) {
                let quoted = read(from: i + 1, until: chars[i])
                var next = quoted.end + 1
                while next < chars.count, chars[next].isWhitespace { next += 1 }
                if quoted.end < chars.count, next == chars.count || chars[next] == "," {
                    args.append(quoted.text)
                    guard next < chars.count else { return args }
                    i = next + 1
                    continue
                }
            }
            let plain = read(from: i, until: ",")
            args.append(plain.text.trimmingCharacters(in: .whitespaces))
            guard plain.end < chars.count else { return args }
            i = plain.end + 1
        }
    }

    /// The canonical name and args of `+js(name, args...)`; nil for a name Scriptlets.js lacks and, outside a trusted list, for the
    /// scriptlets uBO runs only from its own lists, which can rewrite whole pages. `+js()` has an empty name.
    private static func scriptlet(_ selector: String, trusted: Bool) -> (name: String, args: [String])? {
        guard selector.hasSuffix(")") else { return nil }
        let parts = parseScriptletArgs(String(selector.dropFirst(4).dropLast()))
        guard let rawName = parts.first else { return nil }
        if rawName.isEmpty { return parts.count == 1 ? ("", []) : nil }
        // uBO also accepts every name as its resource file, `name.js`.
        let name = rawName.hasSuffix(".js") ? String(rawName.dropLast(3)) : rawName
        let canonical = scriptletAliases[name] ?? name
        guard supportedScriptlets.contains(canonical),
              trusted || !(name.hasPrefix("trusted-") || canonical.hasPrefix("trusted-") || canonical == "replace-node-text") else { return nil }
        return (canonical, Array(parts.dropFirst()))
    }

    /// Splits generic cosmetic selectors: those keyed by a class, id or link host go to GenericCosmetics.js tables (native rules delay
    /// first paint), the rest become css-display-none rules with an unconditional trigger (a condition makes WebKit rebuild them per page)
    /// unless a site excepts them: the scripts read the site exceptions, a native rule needs them as `unless-domain`.
    static func genericCosmetics(from selectors: [String], exceptions: [DomainCosmetic], cap: Int)
        -> (classes: [String], ids: [String], keyed: [String: [String]], links: [String: [String]], cssRules: [[String: Any]]) {
        var classes: [String] = []
        var ids: [String] = []
        var keyed: [String: [String]] = [:]
        var links: [String: [String]] = [:]
        var cssRules: [[String: Any]] = []
        var exceptedOn: [String: [String]] = [:]
        // WebKit has no entity form and rejects a list over one non-ASCII domain: those exceptions cannot apply natively.
        for exception in exceptions {
            exceptedOn[exception.selector, default: []] += exception.domains.filter { !$0.hasSuffix(".*") && $0.allSatisfy(\.isASCII) }
        }
        var seen = Set<String>()
        for selector in selectors where seen.insert(selector).inserted {
            if let token = bareToken(of: selector, prefix: ".") {
                classes.append(token)
            } else if let token = bareToken(of: selector, prefix: "#") {
                ids.append(token)
            } else if let host = linkHost(of: selector) {
                links[host, default: []].append(selector)
            } else if let key = elementToken(of: selector) {
                keyed[key, default: []].append(selector)
            } else {
                var trigger: [String: Any] = ["url-filter": ".*"]
                if let hosts = exceptedOn[selector], !hosts.isEmpty { trigger["unless-domain"] = hosts.map { "*" + $0 } }
                cssRules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
            }
            if seen.count >= cap { break }
        }
        return (classes, ids, keyed, links, cssRules)
    }

    /// A class or id (`.ad`, `#banner`) every element `selector` hides carries, from its last compound:
    /// `div.ad > span` hides spans, whatever their class. nil for a selector list or an escape.
    private static func elementToken(of selector: String) -> String? {
        guard !selector.contains("\\"), !selector.contains(",") else { return nil }
        // The last compound starts after the last combinator outside brackets, parentheses and quoted values.
        var depth = 0
        var quote: Character?
        var start = selector.startIndex
        for index in selector.indices {
            let character = selector[index]
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[", "(": depth += 1
            case "]", ")": depth -= 1
            case " ", ">", "+", "~": if depth == 0 { start = selector.index(after: index) }
            default: break
            }
        }
        guard quote == nil else { return nil }
        let compound = selector[start...]
        depth = 0
        for index in compound.indices {
            let character = compound[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "(" {
                depth += 1
            } else if character == "]" || character == ")" {
                depth -= 1
            } else if depth == 0, character == "." || character == "#" {
                let token = compound[compound.index(after: index)...]
                    .prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
                if !token.isEmpty { return String(character) + token }
            }
        }
        return nil
    }

    /// A link's `[href]` value naming a host (`a[href^="https://ads.example.com/"]`) means the selector
    /// can only match once a link to that host (or a subdomain) exists. Negations are left native.
    private static func linkHost(of selector: String) -> String? {
        guard selector.contains("href"), !selector.contains(":not("), !selector.contains(":has("),
              let match = selector.firstMatch(of: #/(?:^|[\s>+~])a?\[href[\^*]?="(?:https?:)?(?://)?\.?([a-zA-Z0-9][a-zA-Z0-9-]*(?:\.[a-zA-Z0-9-]+)+)/#)
        else { return nil }
        return match.1.lowercased()
    }

    private static func bareToken(of selector: String, prefix: Character) -> String? {
        guard selector.first == prefix else { return nil }
        let token = selector.dropFirst()
        guard !token.isEmpty,
              token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return String(token)
    }

    /// Assemble a per-host selector table. One entry per (host, selector), deduped, stopping once `cap`
    /// total entries are collected.
    static func selectorTable(from cosmetics: [DomainCosmetic], cap: Int) -> [String: [String]] {
        var table: [String: [String]] = [:]
        var seen = Set<String>()
        var count = 0
        outer: for pc in cosmetics {
            for host in pc.domains {
                let key = host + "\u{1}" + pc.selector
                guard seen.insert(key).inserted else { continue }
                table[host, default: []].append(pc.selector)
                count += 1
                if count >= cap { break outer }
            }
        }
        return table
    }

    /// Assemble the per-host scriptlet dispatch table. One entry per (host, name, args), deduped, stopping once `cap` total entries
    /// are collected. An exception's name is prefixed with `@`, and exceptions come first, so the cap never drops one.
    static func scriptletTable(from injections: [ScriptletInjection], exceptions: [ScriptletInjection], cap: Int) -> [String: [[Any]]] {
        var table: [String: [[Any]]] = [:]
        var seen = Set<String>()
        var count = 0
        let all = exceptions.map { ScriptletInjection(domains: $0.domains, name: "@" + $0.name, args: $0.args) } + injections
        outer: for inj in all {
            for host in inj.domains {
                let key = host + "\u{1}" + inj.name + "\u{1}" + inj.args.joined(separator: "\u{1}")
                guard seen.insert(key).inserted else { continue }
                table[host, default: []].append([inj.name, inj.args])
                count += 1
                if count >= cap { break outer }
            }
        }
        return table
    }

    /// The per-host table GenericCosmetics.js reads: each host's selectors, `@selector` for one excepted
    /// there, and `@@` when generic cosmetics are off. Exceptions come first, so the cap never drops one.
    static func siteCosmeticTable(cosmetics: [DomainCosmetic], exceptions: [DomainCosmetic], genericHide: [String],
                                  cap: Int) -> [String: [String]] {
        let entries = genericHide.map { DomainCosmetic(domains: [$0], selector: "@@") }
            + exceptions.map { DomainCosmetic(domains: $0.domains, selector: "@" + $0.selector) }
            + cosmetics
        return selectorTable(from: entries, cap: cap)
    }

    /// Assemble the final rule array: blocks (capped to the remaining budget), then the
    /// css-display-none rules, then exceptions (so their ignore-previous-rules still wins),
    /// then `$important` blocks no exception may override. All but blocks are reserved ahead of blocks.
    static func combinedRules(blocks: [[String: Any]], cssRules: [[String: Any]], exceptions: [[String: Any]],
                              important: [[String: Any]], limit: Int) -> [[String: Any]] {
        let keptExceptions = exceptions.prefix(limit)
        let keptImportant = important.prefix(max(0, limit - keptExceptions.count))
        let blockBudget = max(0, limit - keptExceptions.count - keptImportant.count - cssRules.count)
        var rules = Array(blocks.prefix(blockBudget))
        rules.reserveCapacity(rules.count + cssRules.count + keptExceptions.count + keptImportant.count)
        rules += cssRules
        rules += keptExceptions
        rules += keptImportant
        return rules
    }

    // MARK: - Line

    /// Empty means skip this line (cosmetic, unsupported, or unrepresentable).
    private static func convertLine(_ line: String) -> [NetworkRule] {
        guard !line.hasPrefix("[") else { return [] }
        // Cosmetic filters (element hiding / scriptlets), not network rules.
        if line.contains("##") || line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#") {
            return []
        }
        return networkRules(line)
    }

    typealias NetworkRule = (dict: [String: Any], isException: Bool, isImportant: Bool)

    /// One filter line as content rules: several for a regex with alternatives. Empty when the line
    /// cannot be represented exactly.
    private static func networkRules(_ line: String) -> [NetworkRule] {
        var body = Substring(line)
        var isException = false
        if body.hasPrefix("@@") { isException = true; body = body.dropFirst(2) }

        // A `/regex/` keeps any `$` of its own: its options follow the closing slash.
        var pattern = body
        var optionsStr: Substring?
        let isRegex = body.hasPrefix("/") && body.count > 2 && (body.hasSuffix("/") || body.contains("/$"))
        if isRegex, !body.hasSuffix("/"), let close = body.range(of: "/$", options: .backwards) {
            pattern = body[body.startIndex..<close.upperBound].dropLast()
            optionsStr = body[close.upperBound...]
        } else if !isRegex, let dollar = body.firstIndex(of: "$") {
            pattern = body[body.startIndex..<dollar]
            optionsStr = body[body.index(after: dollar)...]
        }

        var trigger: [String: Any] = [:]
        var isImportant = false
        var requestHosts: [String]?
        if let opts = optionsStr,
           !applyOptions(opts, to: &trigger, important: &isImportant, requestHosts: &requestHosts, isException: isException) { return [] }
        var filters: [String]
        if isRegex, pattern.hasSuffix("/") {
            guard let alternatives = regexURLFilters(pattern.dropFirst().dropLast()) else { return [] }
            filters = alternatives
        } else {
            guard let filter = urlFilter(for: pattern) else { return [] }
            filters = [filter]
        }
        if let requestHosts {
            guard let scoped = requestHostFilters(filters, pattern: pattern, isRegex: isRegex, hosts: requestHosts) else { return [] }
            filters = scoped
        }
        // Matching every URL is only meant for a rule scoped to its sites.
        if filters.contains(".*"), trigger["if-domain"] == nil { return [] }
        // WebKit runs an unanchored filter with an unbounded repetition before its end (`a.*b`, `a[0-9]*b`) over the whole of every
        // request URL: a few hundred dominate the cost of each load.
        let isCostly = { (filter: String) in
            !filter.hasPrefix("^")
                && filter.dropLast(filter.hasSuffix(".*") ? 2 : 0).range(of: #"(?<!\\)[.\])]\*"#, options: .regularExpression) != nil
        }
        if isException {
            // Widening an exception blocks less but never breaks a site: one stops at its first `.*` where what is left stays
            // specific (site-scoped, or 8 characters) and is a whole regex (no group or class cut open).
            filters = filters.map { filter in
                guard isCostly(filter), let star = filter.range(of: #"(?<!\\)\.\*"#, options: .regularExpression) else { return filter }
                let prefix = filter[..<star.lowerBound]
                guard !prefix.isEmpty, prefix.range(of: #"(?<!\\)[\[\]()]"#, options: .regularExpression) == nil,
                      trigger["if-domain"] != nil || prefix.filter({ $0 != "\\" }).count >= 8 else { return filter }
                return String(prefix)
            }
        } else if filters.contains(where: isCostly) {
            // A page rule needs only the navigation's own URL, which WebKit matches once per page as the top URL: the filter moves
            // there, behind one matching every load. `$frame` also maps to "document", so the options name the page types.
            var pageTypes = Set<String>()
            for option in optionsStr?.split(separator: ",") ?? [] {
                switch option.trimmingCharacters(in: .whitespaces) {
                case "document", "doc": pageTypes.insert("document")
                case "popup": pageTypes.insert("popup")
                case "all": pageTypes.formUnion(["document", "popup"])
                default: break
                }
            }
            guard trigger["if-domain"] == nil, trigger["unless-domain"] == nil else { return [] }
            var t = trigger
            t["url-filter"] = ".*"
            t["load-context"] = ["top-frame"]
            t["if-top-url"] = filters
            if let caseSensitive = t.removeValue(forKey: "url-filter-is-case-sensitive") { t["top-url-filter-is-case-sensitive"] = caseSensitive }
            return pageTypes.sorted().map { type in
                t["resource-type"] = [type]
                return (["trigger": t, "action": ["type": "block"]], false, isImportant)
            }
        }

        return filters.map { filter -> NetworkRule in
            var t = trigger
            t["url-filter"] = filter
            return (["trigger": t, "action": ["type": isException ? "ignore-previous-rules" : "block"]], isException, isImportant)
        }
    }

    /// `$to=a|b` keeps a rule to requests to those hosts and their subdomains. Content rules have no request-host condition
    /// (`if-domain` is the page's), so it holds only where the url-filter carries it: a rule matching every URL gets one filter per
    /// host, and one whose filters already pin the host to one of them (`||ads.example.com^`, `/^https:\/\/[a-z]{8}\.com\//`)
    /// keeps them. nil otherwise.
    private static func requestHostFilters(_ filters: [String], pattern: Substring, isRegex: Bool, hosts: [String]) -> [String]? {
        func pins(_ end: String, whole: Bool) -> Bool {
            hosts.contains { end.hasSuffix("." + $0) || (whole && end == $0) }
        }
        if !isRegex, pattern.isEmpty || pattern == "*" {
            return hosts.map { #"^[^:]+://+([^:/]+\.)?"# + escape(Substring($0)) + "[:/]" }
        }
        if !isRegex, pattern.hasPrefix("||") {
            // `||name^`: the host is the name or one of its subdomains.
            let name = pattern.dropFirst(2).prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            let next = pattern.dropFirst(2 + name.count).first
            guard !name.isEmpty, next == "^" || next == "/", pins("." + name, whole: false) else { return nil }
            return filters
        }
        guard isRegex else { return nil }
        for filter in filters {
            guard let pinned = pinnedHostEnd(filter), pins(pinned.end, whole: pinned.whole) else { return nil }
        }
        return filters
    }

    /// The literal end of the host a `regexURLFilters` filter starts with (`.example.com` for `^https:\/\/[a-z]+\.example\.com\/`),
    /// and whether it is the whole host. nil when the host part could reach past the host, or ends in no literal.
    private static func pinnedHostEnd(_ filter: String) -> (end: String, whole: Bool)? {
        guard let scheme = [#"^https:\/\/"#, #"^http:\/\/"#, #"^https?:\/\/"#].first(where: { filter.hasPrefix($0) }) else { return nil }
        let chars = Array(filter.dropFirst(scheme.count))
        // The host part's atoms, nil for one that is not a literal character; it ends at the first `\/`.
        var atoms: [Character?] = []
        var i = 0
        while true {
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == "\\" {
                guard i + 1 < chars.count else { return nil }
                if chars[i + 1] == "/" { break }
                guard chars[i + 1] == "." || chars[i + 1] == "-" else { return nil }
                atoms.append(chars[i + 1])
                i += 2
            } else if c == "[" {
                // Host characters only: a `/`, `?`, `#`, `:` or `@` would let the match leave the host.
                guard let close = chars[i...].firstIndex(of: "]"), close > i + 1 else { return nil }
                let body = chars[(i + 1)..<close]
                guard body.first != "^", body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._\\".contains($0)) }) else { return nil }
                atoms.append(nil)
                i = close + 1
            } else if c == "*" || c == "+" || c == "?" {
                // A repeated group could be anything: only a single atom's quantifier is followed.
                guard let last = atoms.indices.last, chars[i - 1] != ")" else { return nil }
                atoms[last] = nil
                i += 1
            } else if c == "(" || c == ")" {
                i += 1
            } else {
                guard c.isASCII, c.isLetter || c.isNumber || c == "-" || c == "_" else { return nil }
                atoms.append(c)
                i += 1
            }
        }
        let end = String(atoms.reversed().prefix { $0 != nil }.compactMap { $0 }.reversed())
        guard !end.isEmpty else { return nil }
        return (end, end.count == atoms.count)
    }

    /// Url-filters for a uBO `/regex/` in the subset WKContentRuleList accepts (alternatives expanded, repetition unrolled), one per alternative.
    /// Nil for any other construct or an oversized expansion: one rule WebKit rejects makes the whole list fail to compile.
    static func regexURLFilters(_ source: Substring) -> [String]? {
        let chars = Array(source)
        var i = 0
        let maxAlternatives = 16
        let maxRepeat = 48

        func cross(_ a: [String], _ b: [String]) -> [String]? {
            guard a.count * b.count <= maxAlternatives else { return nil }
            return a.flatMap { x in b.map { x + $0 } }
        }
        func classBody() -> String? {
            var out = "["
            i += 1
            if i < chars.count, chars[i] == "^" { out.append("^"); i += 1 }
            var first = true
            while i < chars.count, chars[i] != "]" || first {
                first = false
                let c = chars[i]
                guard c.isASCII, c != "[" else { return nil }
                if c == "\\" {
                    guard i + 1 < chars.count else { return nil }
                    let e = chars[i + 1]
                    switch e {
                    case "d": out += "0-9"
                    case "w": out += "a-zA-Z0-9_"
                    default:
                        guard e.isASCII, !e.isLetter, !e.isNumber else { return nil }
                        out += "\\" + String(e)
                    }
                    i += 2
                } else {
                    out.append(c)
                    i += 1
                }
            }
            guard i < chars.count else { return nil }
            i += 1
            return out + "]"
        }
        // `{n}`, `{n,}` or `{n,m}` at i, as (min, max) with nil max for unbounded.
        func counted() -> (Int, Int?)? {
            guard let close = chars[i...].firstIndex(of: "}") else { return nil }
            let parts = String(chars[(i + 1)..<close]).split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let min = Int(parts[0]) else { return nil }
            let max: Int? = parts.count == 1 ? min : (parts[1].isEmpty ? nil : Int(parts[1]))
            if parts.count == 2, !parts[1].isEmpty, max == nil { return nil }
            i = close + 1
            return (min, max)
        }
        func alternatives(depth: Int) -> [String]? {
            var result: [String] = []
            var current = [""]
            while i < chars.count, chars[i] != ")" {
                let c = chars[i]
                if c == "|" {
                    result += current
                    current = [""]
                    i += 1
                    continue
                }
                var atom: [String]
                switch c {
                case "(":
                    i += 1
                    if i + 1 < chars.count, chars[i] == "?" {
                        guard chars[i + 1] == ":" else { return nil }
                        i += 2
                    }
                    guard let inner = alternatives(depth: depth + 1), i < chars.count, chars[i] == ")" else { return nil }
                    i += 1
                    atom = inner.map { "(" + $0 + ")" }
                case "[":
                    guard let cls = classBody() else { return nil }
                    atom = [cls]
                case "\\":
                    guard i + 1 < chars.count else { return nil }
                    let e = chars[i + 1]
                    i += 2
                    switch e {
                    case "d": atom = ["[0-9]"]
                    case "w": atom = ["[a-zA-Z0-9_]"]
                    default:
                        guard e.isASCII, !e.isLetter, !e.isNumber else { return nil }
                        atom = ["\\" + String(e)]
                    }
                case "^":
                    guard i == 0 else { return nil }
                    i += 1
                    atom = ["^"]
                case "$":
                    guard depth == 0, i == chars.count - 1 else { return nil }
                    i += 1
                    atom = ["$"]
                case "*", "+", "?", "{", "}", "]":
                    return nil
                default:
                    guard c.isASCII, c.unicodeScalars.allSatisfy({ $0.value >= 0x21 }) else { return nil }
                    i += 1
                    atom = [String(c)]
                }
                if i < chars.count, "*+?{".contains(chars[i]), atom != ["^"], atom != ["$"] {
                    let q = chars[i]
                    var range: (Int, Int?)
                    if q == "{" {
                        guard let r = counted() else { return nil }
                        range = r
                    } else {
                        i += 1
                        range = q == "*" ? (0, nil) : q == "+" ? (1, nil) : (0, 1)
                    }
                    // A lazy quantifier matches the same URLs.
                    if i < chars.count, chars[i] == "?" { i += 1 }
                    let (min, max) = range
                    guard min + (max ?? min) <= maxRepeat * 2, min <= maxRepeat else { return nil }
                    if atom.count > 1 {
                        // Alternatives repeat only as optional: (a|b)? is a, b or nothing.
                        guard min == 0, max == 1 else { return nil }
                        atom.append("")
                    } else {
                        let a = atom[0]
                        var expanded = String(repeating: a, count: min)
                        if let max {
                            guard max >= min else { return nil }
                            expanded += String(repeating: a + "?", count: max - min)
                        } else {
                            expanded += a + "*"
                        }
                        atom = [expanded]
                    }
                }
                guard let next = cross(current, atom) else { return nil }
                current = next
            }
            result += current
            guard result.count <= maxAlternatives, !result.contains("") || depth > 0 else { return nil }
            return result
        }
        guard let filters = alternatives(depth: 0), i == chars.count else { return nil }
        return filters
    }

    // MARK: - Built-in extension rules

    /// uBO redirect resources by name, as files of the built-in extension's `resources` folder.
    static let redirectResources: [String: String] = {
        var map: [String: String] = [:]
        let files: [String: [String]] = [
            "noop.js": ["noopjs", "abp-resource:blank-js"], "noop.txt": ["nooptext", "empty", "abp-resource:blank-text"],
            "noop.html": ["noopframe", "abp-resource:blank-html"], "noop.css": ["noopcss", "abp-resource:blank-css"],
            "noop.json": ["noopjson"], "1x1.gif": ["1x1-transparent.gif", "abp-resource:1x1-transparent-gif"],
            "2x2.png": ["2x2-transparent.png", "abp-resource:2x2-transparent-png"],
            "32x32.png": ["32x32-transparent.png", "abp-resource:32x32-transparent-png"],
            "noop-0.1s.mp3": ["noopmp3-0.1s", "abp-resource:blank-mp3"], "noop-1s.mp4": ["noopmp4-1s", "abp-resource:blank-mp4"],
            "noop-vast2.xml": ["noopvast-2.0"], "noop-vast3.xml": ["noopvast-3.0"], "noop-vast4.xml": ["noopvast-4.0"],
            "noop-vmap1.0.xml": ["noopvmap-1.0"], "google-ima.js": ["google-ima3"],
            "googlesyndication_adsbygoogle.js": ["googlesyndication.com/adsbygoogle.js"],
            "googletagservices_gpt.js": ["googletagservices.com/gpt.js"],
            "googletagmanager_gtm.js": ["googletagmanager.com/gtm.js"],
            "google-analytics_analytics.js": ["google-analytics.com/analytics.js"],
            "google-analytics_ga.js": ["google-analytics.com/ga.js"],
            "amazon_apstag.js": ["amazon-adsystem.com/aax2/amzn_ads.js"], "prebid-ads.js": [],
            "nofab.js": ["fuckadblock.js-3.2.0"], "fingerprint2.js": [], "chartbeat.js": ["chartbeat.com/chartbeat.js"],
            "scorecardresearch_beacon.js": ["scorecardresearch.com/beacon.js"],
            "outbrain-widget.js": ["widgets.outbrain.com/outbrain.js"], "popads.js": ["popads.net.js"]
        ]
        for (file, aliases) in files {
            map[file] = file
            for alias in aliases { map[alias] = file }
        }
        return map
    }()

    /// declarativeNetRequest resource types by filter option.
    private static let declarativeTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "stylesheet", "css": "stylesheet", "font": "font",
        "media": "media", "xmlhttprequest": "xmlhttprequest", "xhr": "xmlhttprequest", "websocket": "websocket",
        "ping": "ping", "beacon": "ping", "subdocument": "sub_frame", "frame": "sub_frame", "document": "main_frame",
        "doc": "main_frame", "object": "object", "other": "other"
    ]

    /// What content rules cannot do (`$redirect`, `$redirect-rule`, `$removeparam`) as a declarativeNetRequest rule for the built-in extension,
    /// plus every exception as an outranking `allow`, as uBO exceptions cancel those too. Nil otherwise or when not exactly expressible.
    static func declarativeRule(_ line: String) -> [String: Any]? {
        var body = Substring(line)
        let isException = body.hasPrefix("@@")
        if isException { body = body.dropFirst(2) }
        var pattern = body
        var options: [Substring] = []
        if let dollar = body.firstIndex(of: "$") {
            pattern = body[..<dollar]
            options = body[body.index(after: dollar)...].split(separator: ",")
        }
        guard isException || options.contains(where: { $0.hasPrefix("redirect") || $0.hasPrefix("removeparam") || $0.hasPrefix("rewrite=") }),
              pattern.allSatisfy({ $0.isASCII }), !(pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 1)
        else { return nil }

        var condition: [String: Any] = [:]
        var action: [String: Any]? = isException ? ["type": "allow"] : nil
        var types: [String] = []
        var excludedTypes: [String] = []
        var priority = isException ? 2 : 1
        var removedParameter: String?
        for rawOption in options {
            var option = rawOption.trimmingCharacters(in: .whitespaces)
            let negated = option.hasPrefix("~")
            if negated { option.removeFirst() }
            let parts = option.split(separator: "=", maxSplits: 1)
            let name = String(parts.first ?? "")
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch name {
            case "domain", "from":
                guard !negated else { return nil }
                var included: [String] = []
                var excluded: [String] = []
                for entry in value.split(separator: "|") {
                    let isNegated = entry.hasPrefix("~")
                    let host = String(isNegated ? entry.dropFirst() : entry).lowercased()
                    // Only an exception may drop an exclusion: a redirect would then run on the excluded hosts.
                    if host.hasSuffix(".*") || host.contains("/") {
                        guard isNegated, isException else { return nil }
                        continue
                    }
                    if isNegated { excluded.append(host) } else { included.append(host) }
                }
                if !included.isEmpty { condition["initiatorDomains"] = included }
                if !excluded.isEmpty { condition["excludedInitiatorDomains"] = excluded }
            case "third-party", "3p": condition["domainType"] = negated ? "firstParty" : "thirdParty"
            case "first-party", "1p": condition["domainType"] = negated ? "thirdParty" : "firstParty"
            case "match-case": condition["isUrlFilterCaseSensitive"] = true
            case "important": priority += 2
            case "all", "_": break
            case "redirect", "redirect-rule":
                guard !negated else { return nil }
                if isException { break }
                let resource = value.split(separator: ":").first.map(String.init) ?? ""
                guard let file = redirectResources[resource] else { return nil }
                action = ["type": "redirect", "redirect": ["extensionPath": "/resources/" + file]]
            // ABP's spelling of a redirect, to its own resources only.
            case "rewrite":
                guard !negated, value.hasPrefix("abp-resource:"), let file = redirectResources[value] else { return nil }
                if isException { break }
                action = ["type": "redirect", "redirect": ["extensionPath": "/resources/" + file]]
            case "removeparam":
                guard !negated else { return nil }
                if isException { break }
                guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("|") else { return nil }
                let transform: [String: Any] = value.isEmpty ? ["query": ""] : ["queryTransform": ["removeParams": [value]]]
                action = ["type": "redirect", "redirect": ["transform": transform]]
                removedParameter = value
                // Navigations, frames, fetches and pings carry tracking parameters. declarativeNetRequest leaves
                // navigations out by default, and every subresource a rule matches costs WebKit a redirect check.
                if !options.contains(where: { declarativeTypes[$0.trimmingCharacters(in: .whitespaces)] != nil }) {
                    types = ["main_frame", "ping", "sub_frame", "xmlhttprequest"]
                }
            default:
                guard let type = declarativeTypes[name] else { return nil }
                if negated { excludedTypes.append(type) } else { types.append(type) }
            }
        }
        guard let action else { return nil }
        // A rule only needs the URLs holding the parameter: matching a whole host redirects every navigation
        // and fetch there (YouTube's `||youtube.com^$removeparam=pp`). One emptying every query needs a pattern.
        if let removedParameter {
            if pattern.isEmpty || pattern == "*" {
                guard !removedParameter.isEmpty else { return nil }
                pattern = Substring(removedParameter + "=")
            } else if !removedParameter.isEmpty, !pattern.hasSuffix("|"), !pattern.contains(removedParameter + "=") {
                if pattern.hasSuffix("*") { pattern = pattern.dropLast() }
                pattern += "*" + removedParameter + "="
            }
        }
        // `||*` is not a valid urlFilter: the anchor adds nothing before a wildcard.
        if pattern.hasPrefix("||*") { pattern = pattern.dropFirst(2) }
        if !pattern.isEmpty, pattern != "*" { condition["urlFilter"] = String(pattern) }
        if !types.isEmpty { condition["resourceTypes"] = Array(Set(types)).sorted() }
        if !excludedTypes.isEmpty { condition["excludedResourceTypes"] = Array(Set(excludedTypes)).sorted() }
        return ["priority": priority, "action": action, "condition": condition]
    }

    // MARK: - Options

    /// ABP resource-type option (or its uBO alias) to WKContentRuleList `resource-type` value.
    private static let resourceTypeMap: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet", "font": "font",
        "media": "media", "xmlhttprequest": "raw", "xhr": "raw", "websocket": "raw", "ping": "ping", "beacon": "ping",
        "subdocument": "document", "frame": "document", "document": "document", "doc": "document", "popup": "popup"
    ]

    /// What a rule without a type option applies to; a negated type leaves the others.
    private static let defaultResourceTypes = Set(resourceTypeMap.values).subtracting(["popup"])

    /// Returns false if the rule must be skipped: any option not handled here (redirect, csp, removeparam,
    /// denyallow, generichide, badfilter, ...) changes what the rule means, and dropping it would widen it.
    private static func applyOptions(_ opts: Substring, to trigger: inout [String: Any], important: inout Bool,
                                     requestHosts: inout [String]?, isException: Bool) -> Bool {
        var resourceTypes = Set<String>()
        var excludedTypes = Set<String>()
        for rawOpt in opts.split(separator: ",", omittingEmptySubsequences: true) {
            var opt = rawOpt.trimmingCharacters(in: .whitespaces)
            if opt.isEmpty { continue }
            let negated = opt.hasPrefix("~")
            if negated { opt.removeFirst() }

            // uBO shows the reason on its blocked-page; matching ignores it. A quoted one may hold a comma, splitting it here.
            if opt.hasPrefix("reason=") {
                let value = opt.dropFirst(7)
                guard !negated, !value.hasPrefix("\"") || (value.count > 1 && value.hasSuffix("\"")) else { return false }
                continue
            }
            // Hosts only: an excluded one or an entity cannot be expressed (see requestHostFilters).
            if opt.hasPrefix("to=") {
                let hosts = opt.dropFirst(3).split(separator: "|", omittingEmptySubsequences: false).map { $0.lowercased() }
                guard !negated, hosts.allSatisfy({ host in
                    !host.isEmpty && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
                }) else { return false }
                requestHosts = hosts
                continue
            }
            if opt.hasPrefix("domain=") || opt.hasPrefix("from=") {
                guard !negated, let eq = opt.firstIndex(of: "="),
                      applyDomainOption(opt[opt.index(after: eq)...], to: &trigger, isException: isException) else { return false }
                continue
            }
            switch opt {
            case "third-party", "3p": trigger["load-type"] = [negated ? "first-party" : "third-party"]
            case "first-party", "1p": trigger["load-type"] = [negated ? "third-party" : "first-party"]
            // Narrower than strict3p, which also matches other hosts of the same site.
            case "strict3p" where !negated: trigger["load-type"] = ["third-party"]
            case "match-case": trigger["url-filter-is-case-sensitive"] = true
            case "important": important = true
            case "all", "_": break
            default:
                guard let rt = resourceTypeMap[opt] else { return false }
                if negated { excludedTypes.insert(rt) } else { resourceTypes.insert(rt) }
            }
        }
        if resourceTypes.isEmpty, !excludedTypes.isEmpty {
            resourceTypes = defaultResourceTypes.subtracting(excludedTypes)
            if resourceTypes.isEmpty { return false }
        }
        if !resourceTypes.isEmpty {
            trigger["resource-type"] = resourceTypes.sorted()
        }
        return true
    }

    /// Returns false when the domain list can't be expressed without widening the rule: WKContentRuleList
    /// has no `example.*` entity form, so those entries are dropped, which only a positive list survives.
    /// WebKit rejects a whole list over one non-ASCII domain.
    private static func applyDomainOption(_ value: Substring, to trigger: inout [String: Any], isException: Bool) -> Bool {
        // A uBO `/regex/` entry, which may itself contain "|".
        guard !value.contains("/"), value.allSatisfy(\.isASCII) else { return false }
        var ifDomain: [String] = []
        var unlessDomain: [String] = []
        var droppedEntity = false
        for d in value.split(separator: "|") {
            let neg = d.hasPrefix("~")
            let host = String(neg ? d.dropFirst() : d).lowercased()
            guard !host.isEmpty else { continue }
            if host.hasSuffix(".*") { droppedEntity = true; continue }
            let entry = "*" + host  // WKContentRuleList: leading "*" matches the domain and its subdomains
            if neg { unlessDomain.append(entry) } else { ifDomain.append(entry) }
        }
        // WKContentRuleList can't combine if-domain and unless-domain. Only an exception may drop the
        // exclusions: a block would then run on the excluded hosts.
        if !ifDomain.isEmpty {
            guard unlessDomain.isEmpty || isException else { return false }
            trigger["if-domain"] = ifDomain
            return true
        }
        guard !droppedEntity else { return false }
        if !unlessDomain.isEmpty {
            trigger["unless-domain"] = unlessDomain
        }
        return true
    }

    // MARK: - URL filter

    static func urlFilter(for pattern: Substring) -> String? {
        var p = pattern
        var prefix = ""
        if p.hasPrefix("||") {
            p = p.dropFirst(2)
            prefix = "^https?://([^/]+\\.)?"  // domain anchor: scheme + optional subdomains
        } else if p.hasPrefix("|") {
            p = p.dropFirst()
            prefix = "^"
        }
        var suffix = ""
        if p.hasSuffix("|") {
            p = p.dropLast()
            suffix = "$"
        }
        // An unanchored filter matches anywhere in the URL: a leading wildcard adds nothing.
        if prefix.isEmpty { while p.hasPrefix("*") { p = p.dropFirst() } }
        // Every URL: the caller only keeps that for a rule scoped to its sites.
        guard !p.isEmpty else { return prefix.isEmpty && suffix.isEmpty ? ".*" : nil }
        // WebKit rejects the whole list over one non-ASCII url-filter.
        guard p.allSatisfy(\.isASCII) else { return nil }
        return prefix + escape(p) + suffix
    }

    private static func escape(_ s: Substring) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            switch ch {
            case "*": out += ".*"
            case "^": out += "[^-a-zA-Z0-9._%]"  // ABP separator: any non-(alnum/._%-) char
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|":
                out.append("\\"); out.append(ch)
            default: out.append(ch)
            }
        }
        return out
    }
}
