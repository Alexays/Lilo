import Foundation
import JavaScriptCore

enum ExtensionBackgroundPreparer {
    enum PreparationResult: Equatable {
        case notNeeded
        case prepared
        case skipped
    }

    enum PreparationError: Error {
        case unsafeWriteTarget(path: String)
    }

    private static let metadataDirectory = "_lilo"
    private static let wrapperPath = "lilo-background-wrapper.js"
    private static let preludePath = "lilo-background-prelude.js"
    private static let publicSuffixListPath = "public-suffix-list.dat"

    /// The bundled list behind chrome.publicSuffix, and the prelude line handing it to the worker.
    private static let publicSuffixList: (data: Data, preludeLine: String)? = Bundle.appResourceURL("public-suffix-list", extension: "dat")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { (Data($0.utf8), "globalThis.__liloPublicSuffixList = \(javaScriptStringLiteral($0));\n") }

    /// Both steps share one manifest parse; the content-script step sees the background patch in memory.
    /// The manifest is written at most once, and only when a step changed it.
    static func prepare(extensionURL: URL, preludeSource: String, compatSource: String? = nil) throws -> PreparationResult {
        guard var manifest = try readManifest(at: extensionURL) else { return .notNeeded }
        let original = manifest as NSDictionary
        acceptAsChrome(&manifest)
        try prepareStaticRulesets(extensionURL: extensionURL, manifest: manifest)
        var preludeSource = preludeSource
        // chrome.publicSuffix is synchronous: its list is in the worker's prelude, and a file pages read.
        if (manifest["permissions"] as? [String])?.contains("publicSuffix") == true, let publicSuffixList {
            let metadataDir = extensionURL.appendingPathComponent(metadataDirectory, isDirectory: true)
            let listURL = metadataDir.appendingPathComponent(publicSuffixListPath)
            for target in [metadataDir, listURL] {
                try verifyWriteTargetInside(extensionURL, target: target)
            }
            try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
            try writeIfChanged(publicSuffixList.data, to: listURL)
            preludeSource = publicSuffixList.preludeLine + preludeSource
        }
        let result = try prepareBackground(extensionURL: extensionURL, manifest: &manifest, preludeSource: preludeSource)
        if let compatSource {
            try prepareContentScriptCompat(extensionURL: extensionURL, manifest: &manifest, compatSource: compatSource)
        }
        if !original.isEqual(to: manifest) {
            let manifestURL = extensionURL.appendingPathComponent("manifest.json")
            try verifyWriteTargetInside(extensionURL, target: manifestURL)
            try writeIfChanged(try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), to: manifestURL)
        }
        return result
    }

    private static func readManifest(at extensionURL: URL) throws -> [String: Any]? {
        let manifestURL = extensionURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
    }

    private static func prepareBackground(extensionURL: URL, manifest: inout [String: Any], preludeSource: String) throws -> PreparationResult {
        guard var background = manifest["background"] as? [String: Any],
              let serviceWorker = background["service_worker"] as? String,
              !serviceWorker.isEmpty else {
            return .notNeeded
        }

        let metadataDir = extensionURL.appendingPathComponent(metadataDirectory, isDirectory: true)
        let originalServiceWorker: String
        let originalType: String

        // A manifest pointing at Lilo's wrapper names the vendor worker only in the recorded metadata.
        if isLiloManagedPath(serviceWorker), let metadata = try readMetadata(from: metadataDir) {
            originalServiceWorker = metadata.originalServiceWorker
            originalType = metadata.originalType
        } else if isLiloManagedPath(serviceWorker) {
            // A wrapper with no recoverable metadata: the real entry point is unknown, and
            // wrapping it again would lose it permanently. Leave the extension untouched.
            return .skipped
        } else {
            // A vendor path in the manifest is the truth, even over recorded metadata: an unpacked
            // extension edited in place may now name a different worker.
            // Chrome resolves "./js/sw.js" and "/js/sw.js" against the extension root, like "js/sw.js".
            var path = Substring(serviceWorker)
            if path.hasPrefix("./") { path = path.dropFirst(2) }
            while path.hasPrefix("/") { path = path.dropFirst() }
            originalServiceWorker = String(path)
            originalType = (background["type"] as? String) == "module" ? "module" : "classic"
        }

        guard isSafeRelativeExtensionPath(originalServiceWorker) else { return .skipped }

        // The wrapper is the registered script, so it sets the base URL of every relative fetch/importScripts: it lives beside the vendor
        // worker to keep subdirectory workers' sub-resources resolving. `originalServiceWorker` keeps the root-relative path.
        let workerDirectory = (originalServiceWorker as NSString).deletingLastPathComponent
        let workerBasename = (originalServiceWorker as NSString).lastPathComponent
        let wrapperRelativePath = (workerDirectory as NSString).appendingPathComponent(wrapperPath)
        let preludeRelativePath = (workerDirectory as NSString).appendingPathComponent(preludePath)

        // The extension directory can originate from an untrusted unpacked archive.
        // Refuse to follow symlinks for any write target: each must resolve to a path
        // that still resides inside the extension directory, or we abort without writing.
        let wrapperURL = extensionURL.appendingPathComponent(wrapperRelativePath)
        let preludeURL = extensionURL.appendingPathComponent(preludeRelativePath)
        for target in [metadataDir, wrapperURL, preludeURL] {
            try verifyWriteTargetInside(extensionURL, target: target)
        }

        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrapperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The wrapper is the registered script: the prelude reports the vendor worker as `location`.
        var workerLine = "globalThis.__liloWorkerScript = \(javaScriptStringLiteral(workerBasename));\n"
        // A module worker has no importScripts.
        if originalType == "classic" {
            let empty = emptyScripts(in: extensionURL)
            if !empty.isEmpty {
                workerLine += "globalThis.__liloEmptyScripts = [\(empty.map(javaScriptStringLiteral).joined(separator: ", "))];\n"
            }
        }
        try writeIfChanged(Data((workerLine + preludeSource).utf8), to: preludeURL)
        try writeIfChanged(Data(backgroundWrapperSource(workerBasename: workerBasename, type: originalType).utf8), to: wrapperURL)
        let metadata: [String: Any] = [
            "schema": 1,
            "preparedBy": "Lilo",
            "originalServiceWorker": originalServiceWorker,
            "originalType": originalType
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try writeIfChanged(metadataData, to: metadataDir.appendingPathComponent("metadata.json"))

        background["service_worker"] = wrapperRelativePath
        // WebKit runs `scripts` or `page`, kept for Firefox, over the service worker; Chrome runs the worker.
        if background["scripts"] != nil || background["page"] != nil || background["preferred_environment"] != nil {
            background["preferred_environment"] = "service_worker"
        }
        if originalType == "module" {
            background["type"] = "module"
        } else {
            background.removeValue(forKey: "type")
        }
        manifest["background"] = background
        return .prepared
    }

    /// Schemes WebKit grants web_accessible_resources to (chrome-extension once the app registers it);
    /// it rejects the whole entry list over any other.
    private static let webAccessibleSchemes: Set<String> = ["*", "http", "https", "file", "webkit-extension", "chrome-extension"]

    /// Rewrites the manifest entries Chrome accepts and WebKit rejects into their WebKit equivalent.
    private static func acceptAsChrome(_ manifest: inout [String: Any]) {
        // WebKit requires a description, Chrome shows none when there is none: a blank one stands in.
        if ((manifest["description"] as? String) ?? "").isEmpty {
            manifest["description"] = " "
        }
        // Chrome ignores a host permission's path (`https://*/` reaches every page of every host); WebKit matches it.
        for key in ["host_permissions", "optional_host_permissions"] {
            guard let patterns = manifest[key] as? [Any] else { continue }
            manifest[key] = patterns.map { entry -> Any in
                guard let pattern = entry as? String, let hostStart = pattern.range(of: "://")?.upperBound,
                      let pathStart = pattern[hostStart...].firstIndex(of: "/") else { return entry }
                return String(pattern[..<pathStart]) + "/*"
            }
        }
        if var commands = manifest["commands"] as? [String: Any] {
            // WebKit rejects an empty `_execute_action`, and adds that command itself for the action.
            if (commands["_execute_action"] as? [String: Any])?.isEmpty == true {
                commands["_execute_action"] = nil
            }
            // Chrome trims the whitespace around each key: "Ctrl + Shift + Y" is Ctrl+Shift+Y.
            for (name, value) in commands {
                guard var command = value as? [String: Any], let keys = command["suggested_key"] as? [String: Any] else { continue }
                command["suggested_key"] = keys.mapValues { key in
                    (key as? String).map { key in
                        key.split(separator: "+", omittingEmptySubsequences: false)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .joined(separator: "+")
                    } ?? key
                }
                commands[name] = command
            }
            manifest["commands"] = commands
        }
        // An empty policy object means Chrome's default policy, which WebKit applies when there is none.
        if (manifest["content_security_policy"] as? [String: Any])?.isEmpty == true {
            manifest["content_security_policy"] = nil
        }
        // WebKit rejects an empty list, which declares nothing in Chrome.
        if (manifest["content_scripts"] as? [Any])?.isEmpty == true {
            manifest["content_scripts"] = nil
        }
        if var connectable = manifest["externally_connectable"] as? [String: Any] {
            // WebKit's patterns have no <all_urls> and no port; Chrome's match any port when they name none,
            // so a named port widens to every port of its host.
            let matches = (connectable["matches"] as? [Any] ?? []).compactMap { $0 as? String }.map { pattern -> String in
                if pattern == "<all_urls>" { return "*://*/*" }
                guard let hostStart = pattern.range(of: "://")?.upperBound else { return pattern }
                let hostEnd = pattern[hostStart...].firstIndex(of: "/") ?? pattern.endIndex
                guard let colon = pattern[hostStart..<hostEnd].lastIndex(of: ":") else { return pattern }
                let port = pattern[pattern.index(after: colon)..<hostEnd]
                guard port == "*" || UInt16(port) != nil else { return pattern }
                return String(pattern[..<colon] + pattern[hostEnd...])
            }
            connectable["matches"] = matches.isEmpty ? nil : matches
            // With no matches and no ids, Chrome lets nothing connect, and WebKit rejects the entry.
            let grantsNothing = matches.isEmpty && (connectable["ids"] as? [Any])?.isEmpty != false
            manifest["externally_connectable"] = grantsNothing ? nil : connectable
        }
        // `extension_ids` grants nothing in Lilo: an entry left with no matches is dropped.
        if manifest["manifest_version"] as? Int == 3, let entries = manifest["web_accessible_resources"] as? [Any] {
            manifest["web_accessible_resources"] = entries.compactMap { entry -> Any? in
                guard var resource = entry as? [String: Any], resource["resources"] is [Any] else { return entry }
                let matches = (resource["matches"] as? [Any] ?? []).compactMap { $0 as? String }.filter { pattern in
                    pattern == "<all_urls>" || (pattern.contains("://") && webAccessibleSchemes.contains(String(pattern.prefix { $0 != ":" })))
                }
                guard !matches.isEmpty else { return nil }
                resource["matches"] = matches
                return resource
            }
        }
    }

    /// The bundled dnr-rules.ts code that puts static rulesets in the form WebKit applies.
    private static let staticRulesScript: String? = Bundle.appResourceURL("ChromeStaticRules", extension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static let staticRulesStampPath = "static-rulesets.txt"

    /// Rewrites the static declarativeNetRequest rulesets in place as Lilo sends dynamic rules: WebKit
    /// skips a rule it cannot compile and fails every ruleset past its rule cap. The files' sizes and
    /// dates, stamped once they are prepared, skip the work on later launches.
    private static func prepareStaticRulesets(extensionURL: URL, manifest: [String: Any]) throws {
        let rulesets = staticRulesets(extensionURL: extensionURL, manifest: manifest)
        guard !rulesets.isEmpty, let staticRulesScript else { return }
        let urls = rulesets.map(\.url)
        let stampURL = extensionURL.appendingPathComponent(metadataDirectory, isDirectory: true).appendingPathComponent(staticRulesStampPath)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == staticRulesetsStamp(urls) { return }

        let context = JSContext()
        context?.evaluateScript(staticRulesScript)
        let sources = urls.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
        guard let prepared = context?.objectForKeyedSubscript("LiloStaticRules")?.objectForKeyedSubscript("webKitStaticRulesets")?
            .call(withArguments: [sources])?.toArray(), prepared.count == urls.count else { return }
        for (url, ruleset) in zip(urls, prepared) {
            guard let ruleset = ruleset as? String else { continue }
            try verifyWriteTargetInside(extensionURL, target: url)
            try writeIfChanged(Data(ruleset.utf8), to: url)
        }
        // Preparing restores each inert rule's original: the disabled ones turn inert again.
        var disabled = readDisabledStaticRules(extensionURL: extensionURL)
        for (rulesetId, rules) in disabled {
            guard let url = rulesets.first(where: { $0.id == rulesetId })?.url else { continue }
            let ids = Set(rules.keys.compactMap { Int($0) })
            disabled[rulesetId] = try rewriteRuleset(extensionURL: extensionURL, at: url, disabling: ids, restoring: [:])
                .before.reduce(into: [:]) { $0[String($1.key)] = $1.value }
        }
        if !disabled.isEmpty { try writeMetadataFile(extensionURL: extensionURL, disabledStaticRulesPath, disabled) }
        try writeStaticRulesetsStamp(extensionURL: extensionURL, urls: urls)
    }

    private static let disabledStaticRulesPath = "disabled-static-rules.json"
    /// Chrome's MAX_NUMBER_OF_DISABLED_STATIC_RULES, which its schema no longer exposes.
    private static let maxDisabledStaticRules = 5000

    enum StaticRulesError: LocalizedError {
        case invalidRulesetId(String)
        case tooManyDisabledRules

        var errorDescription: String? {
            switch self {
            case .invalidRulesetId(let id): "Invalid ruleset id: \(id)."
            case .tooManyDisabledRules: "The number of disabled static rules exceeds the disabled rule count limit."
            }
        }
    }

    /// The manifest's static rulesets, by id, at the paths Lilo may write.
    static func staticRulesets(extensionURL: URL, manifest: [String: Any]) -> [(id: String?, url: URL)] {
        let resources = (manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]] ?? []
        return resources.compactMap { resource in
            guard var path = (resource["path"] as? String)?[...] else { return nil }
            if path.hasPrefix("./") { path = path.dropFirst(2) }
            while path.hasPrefix("/") { path = path.dropFirst() }
            return isSafeRelativeExtensionPath(String(path)) ? (resource["id"] as? String, extensionURL.appendingPathComponent(String(path))) : nil
        }
    }

    private static func staticRulesetsStamp(_ urls: [URL]) -> String {
        urls.map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return "\((attributes?[.size] as? Int) ?? -1) \((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(url.path)"
        }.joined(separator: "\n")
    }

    private static func writeStaticRulesetsStamp(extensionURL: URL, urls: [URL]) throws {
        try writeMetadataFile(extensionURL: extensionURL, staticRulesStampPath, Data(staticRulesetsStamp(urls).utf8))
    }

    /// Writes `contents` (Data, or a JSON object) to `_lilo/<name>`.
    private static func writeMetadataFile(extensionURL: URL, _ name: String, _ contents: Any) throws {
        let metadataDir = extensionURL.appendingPathComponent(metadataDirectory, isDirectory: true)
        let url = metadataDir.appendingPathComponent(name)
        for target in [metadataDir, url] {
            try verifyWriteTargetInside(extensionURL, target: target)
        }
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try writeIfChanged(contents as? Data ?? JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys]), to: url)
    }

    /// Each ruleset's disabled rule ids, each with the rule its file held before it turned inert (null for an id no rule has).
    private static func readDisabledStaticRules(extensionURL: URL) -> [String: [String: Any]] {
        let url = extensionURL.appendingPathComponent(metadataDirectory, isDirectory: true).appendingPathComponent(disabledStaticRulesPath)
        return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
    }

    /// Turns the rules of `ids` inert in the ruleset file, as WebKit is given rules it cannot apply, and puts `restoring`
    /// back. Returns each of `ids` with the rule it had before (NSNull for an id no rule has), and whether the file changed.
    private static func rewriteRuleset(
        extensionURL: URL, at url: URL, disabling ids: Set<Int>, restoring: [Int: Any]
    ) throws -> (before: [Int: Any], changed: Bool) {
        var rules = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any] ?? []
        var before: [Int: Any] = [:]
        var changed = false
        for index in rules.indices {
            guard let rule = rules[index] as? [String: Any], let id = rule["id"] as? Int else { continue }
            if ids.contains(id) {
                before[id] = rule
                // dnr-rules.ts's inert form (INERT_FILTER, STORED_RULE), which testMatchOutcome skips.
                rules[index] = [
                    "id": id, "action": ["type": "block"], "condition": ["regexFilter": "^lilo-inert-rule:"],
                    "liloChromeRule": rule["liloChromeRule"] ?? rule
                ] as [String: Any]
                changed = true
            } else if let original = restoring[id] as? [String: Any] {
                rules[index] = original
                changed = true
            }
        }
        if changed {
            try verifyWriteTargetInside(extensionURL, target: url)
            try writeIfChanged(JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes]), to: url)
        }
        for id in ids where before[id] == nil { before[id] = NSNull() }
        return (before, changed)
    }

    /// chrome.declarativeNetRequest.getDisabledRuleIds.
    static func disabledStaticRuleIds(extensionURL: URL, rulesets: [(id: String?, url: URL)], rulesetId: String) throws -> [Int] {
        guard rulesets.contains(where: { $0.id == rulesetId }) else {
            throw StaticRulesError.invalidRulesetId(rulesetId)
        }
        return (readDisabledStaticRules(extensionURL: extensionURL)[rulesetId] ?? [:]).keys.compactMap { Int($0) }.sorted()
    }

    /// chrome.declarativeNetRequest.updateStaticRules: a disabled rule turns inert in its ruleset's file, which WebKit
    /// reads on its next compile. Returns whether the file changed.
    static func updateStaticRules(extensionURL: URL, rulesets: [(id: String?, url: URL)], rulesetId: String, disable: [Int], enable: [Int]) throws -> Bool {
        guard let url = rulesets.first(where: { $0.id == rulesetId })?.url else { throw StaticRulesError.invalidRulesetId(rulesetId) }
        var state = readDisabledStaticRules(extensionURL: extensionURL)
        let saved = state[rulesetId] ?? [:]
        let before = Set(saved.keys.compactMap { Int($0) })
        // As in Chrome, an id in both lists ends enabled.
        let after = before.union(disable).subtracting(enable)
        guard after != before else { return false }
        guard after.count <= maxDisabledStaticRules else { throw StaticRulesError.tooManyDisabledRules }
        let restoring = Dictionary(uniqueKeysWithValues: before.subtracting(after).map { ($0, saved[String($0)] ?? NSNull()) })
        let (disabled, changed) = try rewriteRuleset(extensionURL: extensionURL, at: url, disabling: after.subtracting(before), restoring: restoring)
        var updated = saved.filter { after.contains(Int($0.key) ?? -1) }
        for (id, rule) in disabled { updated[String(id)] = rule }
        state[rulesetId] = updated.isEmpty ? nil : updated
        try writeMetadataFile(extensionURL: extensionURL, disabledStaticRulesPath, state)
        try writeStaticRulesetsStamp(extensionURL: extensionURL, urls: rulesets.map(\.url))
        return changed
    }

    private static let contentCompatPath = "_lilo/lilo-content-compat.js"

    /// Prepends a compat content script to every isolated-world JS entry so APIs WebKit omits there (`chrome.storage.managed`) exist
    /// before the extension's scripts; never MAIN-world, where it would leak. Rewritten on every call so Lilo updates apply.
    private static func prepareContentScriptCompat(extensionURL: URL, manifest: inout [String: Any], compatSource: String) throws {
        guard var contentScripts = manifest["content_scripts"] as? [[String: Any]],
              !contentScripts.isEmpty else { return }

        var changed = false
        for index in contentScripts.indices {
            guard let js = contentScripts[index]["js"] as? [String], !js.isEmpty else { continue }
            var updated = js
            updated.removeAll { $0 == contentCompatPath }
            if (contentScripts[index]["world"] as? String)?.uppercased() != "MAIN" {
                updated.insert(contentCompatPath, at: 0)
            }
            guard updated != js else { continue }
            contentScripts[index]["js"] = updated
            changed = true
        }

        let metadataDir = extensionURL.appendingPathComponent(metadataDirectory, isDirectory: true)
        let compatURL = extensionURL.appendingPathComponent(contentCompatPath)
        try verifyWriteTargetInside(extensionURL, target: metadataDir)
        try verifyWriteTargetInside(extensionURL, target: compatURL)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try writeIfChanged(Data(compatSource.utf8), to: compatURL)

        if changed { manifest["content_scripts"] = contentScripts }
    }

    /// The extension's scripts holding only whitespace, root-relative ("/test.js"): the prelude skips
    /// their import, which in WebKit would run the worker's pending promise callbacks (gap 14).
    private static func emptyScripts(in extensionURL: URL) -> [String] {
        let root = extensionURL.standardizedFileURL.path
        guard let files = FileManager.default.enumerator(
            at: extensionURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var empty: [String] = []
        for case let url as URL in files where url.pathExtension == "js" {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64,
                  let data = try? Data(contentsOf: url),
                  data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(root + "/") { empty.append(String(path.dropFirst(root.count))) }
        }
        return empty.sorted()
    }

    private struct Metadata {
        let originalServiceWorker: String
        let originalType: String
    }

    /// Atomic write skipped when the bytes already match: prepare runs on every launch and every
    /// background revive, and rewriting identical files is pure temp-file + rename churn.
    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    /// Paths Lilo writes into the extension, never the vendor's own entry point. The wrapper/prelude
    /// are matched by basename in any directory: they sit next to the vendor worker, so
    /// `js/lilo-background-wrapper.js` is ours too.
    private static func isLiloManagedPath(_ path: String) -> Bool {
        let basename = (path as NSString).lastPathComponent
        return basename == wrapperPath || basename == preludePath || path.hasPrefix("_lilo/")
    }

    private static func readMetadata(from liloDir: URL) throws -> Metadata? {
        let metadataURL = liloDir.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let data = try Data(contentsOf: metadataURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? Int == 1,
              let originalServiceWorker = object["originalServiceWorker"] as? String,
              let originalType = object["originalType"] as? String else {
            return nil
        }
        return Metadata(originalServiceWorker: originalServiceWorker, originalType: originalType)
    }

    /// Ensures `target` is not a symlink that escapes the extension directory.
    /// Resolves symlinks on both the extension root and the target's existing parent
    /// chain, then verifies the target still lives inside the resolved extension root.
    private static func verifyWriteTargetInside(_ extensionURL: URL, target: URL) throws {
        let resolvedRoot = extensionURL.resolvingSymlinksInPath().standardizedFileURL
        // Resolve the deepest existing ancestor (the target itself may not exist yet),
        // then re-append the not-yet-created trailing components.
        var ancestors: [String] = []
        var probe = target.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            ancestors.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()
        }
        var resolvedTarget = probe.resolvingSymlinksInPath().standardizedFileURL
        for component in ancestors {
            resolvedTarget.appendPathComponent(component)
        }
        resolvedTarget = resolvedTarget.standardizedFileURL

        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedTarget.path == resolvedRoot.path || resolvedTarget.path.hasPrefix(rootPath) else {
            throw PreparationError.unsafeWriteTarget(path: target.path)
        }
    }

    private static func isSafeRelativeExtensionPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..") && !components.contains { $0.hasPrefix(".") }
    }

    /// `workerBasename` has no directory: the wrapper sits beside the worker, preserving its base URL. `__liloWorkerReady` runs after
    /// the worker's top-level code, so the events that woke it reach the listeners it registers there, as in Chrome.
    private static func backgroundWrapperSource(workerBasename: String, type: String) -> String {
        if type == "module" {
            return "import './\(preludePath)';\nimport \(javaScriptStringLiteral("./" + workerBasename));\nglobalThis.__liloWorkerReady?.();\n"
        }
        return "importScripts('\(preludePath)');\ntry {\n  importScripts(\(javaScriptStringLiteral(workerBasename)));\n} finally {\n  globalThis.__liloWorkerReady?.();\n}\n"
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
