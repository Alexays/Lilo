import WebKit

/// `chrome.userScripts` for one profile: each loaded extension's registrations and world
/// configurations, persisted, and the `WKUserScript`s they install into the profile's tabs, with the
/// `chrome.runtime` of the pages an extension's `externally_connectable` names.
@MainActor
final class ExtensionUserScripts {
    /// What `chrome.userScripts` and `externally_connectable` inject for one extension into this profile's tabs.
    struct Install {
        let scripts: [WKUserScript]
        /// The USER_SCRIPT worlds of `scripts` configured with `messaging`.
        let messagingWorlds: [WKContentWorld]
        let allowsPrivateAccess: Bool
    }

    /// A built user script and every input of its build besides the extension's files, which only
    /// change with a reload.
    private struct Built {
        let registration: ExtensionStorage.UserScript
        let include: [String]
        let messaging: Bool
        let script: WKUserScript
    }

    private struct Registrations {
        var scripts: [ExtensionStorage.UserScript] = []
        var worlds: [ExtensionStorage.UserScriptWorld] = []
        /// Installed user scripts by registration id, reused while their inputs are unchanged.
        var built: [String: Built] = [:]
    }

    /// By loaded extension.
    private var registrations: [String: Registrations] = [:]
    private(set) var installs: [String: Install] = [:]
    /// By loaded extension whose `externally_connectable` names pages.
    private var connectableScripts: [String: WKUserScript] = [:]
    /// Removes `removed` from the profile's tabs, then adds `added` under `install`'s rules. Set by
    /// the engine factory, which owns the tabs' content controllers.
    var onChange: ((_ removed: [WKUserScript], _ added: [WKUserScript], _ install: Install?) -> Void)?
    private var pendingReinstalls: Set<String> = []

    private let storage: ExtensionStorage
    private let access: ExtensionAccess
    /// The scripts every extension page of the profile runs.
    private let pageScripts: WKUserContentController
    /// Names the extensions allowed to use user scripts, for their pages' `chrome.userScripts`.
    private var switchScript: WKUserScript?
    /// The loaded context of an extension and the folder it runs from.
    private let runtime: (String) -> (context: WKWebExtensionContext, sourcePath: String)?

    init(
        storage: ExtensionStorage,
        access: ExtensionAccess,
        pageScripts: WKUserContentController,
        runtime: @escaping (String) -> (context: WKWebExtensionContext, sourcePath: String)?
    ) {
        self.storage = storage
        self.access = access
        self.pageScripts = pageScripts
        self.runtime = runtime
    }

    /// Reads the stored registrations of an extension that declares `userScripts` and installs them.
    func loaded(_ extensionId: String) async {
        guard let stored = try? await storage.loadUserScripts(extensionId: extensionId), runtime(extensionId) != nil else { return }
        registrations[extensionId] = Registrations(scripts: stored.scripts, worlds: stored.worlds)
        reinstall(for: extensionId)
    }

    func unloaded(_ extensionId: String) {
        registrations[extensionId] = nil
        connectableScripts[extensionId] = nil
        reinstall(for: extensionId)
    }

    /// The extension's registrations and world configurations; nil when it is not loaded.
    func registrations(of extensionId: String) -> (scripts: [ExtensionStorage.UserScript], worlds: [ExtensionStorage.UserScriptWorld])? {
        guard runtime(extensionId) != nil else { return nil }
        let current = registrations[extensionId]
        return (current?.scripts ?? [], current?.worlds ?? [])
    }

    /// Replaces the extension's registrations and/or world configurations, applies them to open tabs
    /// and persists them.
    func set(_ scripts: [ExtensionStorage.UserScript]?, worlds: [ExtensionStorage.UserScriptWorld]?, for extensionId: String) async {
        guard runtime(extensionId) != nil else { return }
        if let scripts { registrations[extensionId, default: Registrations()].scripts = scripts }
        if let worlds { registrations[extensionId, default: Registrations()].worlds = worlds }
        // Calls arriving while this one persists share one reinstall.
        if pendingReinstalls.insert(extensionId).inserted, pendingReinstalls.count == 1 {
            Task { @MainActor [weak self] in self?.flushReinstalls() }
        }
        if let scripts { try? await storage.setUserScripts(scripts, extensionId: extensionId) }
        if let worlds { try? await storage.setUserScriptWorlds(worlds, extensionId: extensionId) }
        // Applied before the caller replies, even when nothing above suspended.
        flushReinstalls()
    }

    private func flushReinstalls() {
        pendingReinstalls.forEach(reinstall(for:))
    }

    func reinstall(for extensionId: String) {
        pendingReinstalls.remove(extensionId)
        let previous = installs.removeValue(forKey: extensionId)
        let loaded = runtime(extensionId)
        var current = loaded.flatMap { makeInstall(extensionId, context: $0.context, sourcePath: $0.sourcePath) }
        if let connectable = loaded.flatMap({ connectableScript(extensionId, context: $0.context) }) {
            current = Install(
                scripts: (current?.scripts ?? []) + [connectable], messagingWorlds: current?.messagingWorlds ?? [],
                allowsPrivateAccess: access.states[extensionId]?.allowsPrivateAccess == true
            )
        }
        installs[extensionId] = current
        let old = previous?.scripts ?? [], new = current?.scripts ?? []
        // The unchanged leading scripts stay; everything after the first change is swapped so the
        // injection order stays the registration order. A private-access change swaps them all.
        var kept = 0
        if previous?.allowsPrivateAccess == current?.allowsPrivateAccess {
            while kept < old.count, kept < new.count, old[kept] === new[kept] { kept += 1 }
        }
        guard kept < old.count || kept < new.count else { return }
        onChange?(Array(old[kept...]), Array(new[kept...]), current)
    }

    /// Pages opened from now on learn which extensions may use user scripts; open ones keep what they
    /// had. Without the private removal the new script is appended: the last assignment wins.
    func publishSwitches() {
        let allowed = access.states.compactMap { $0.value.allowsUserScripts == true ? $0.key : nil }.sorted()
        let json = (try? JSONSerialization.data(withJSONObject: allowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let removeSelector = NSSelectorFromString("_removeUserScript:")
        if let previous = switchScript, pageScripts.responds(to: removeSelector) {
            _ = pageScripts.perform(removeSelector, with: previous)
        }
        let script = WKUserScript(source: "globalThis.__liloUserScriptsAllowedIds = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        pageScripts.addUserScript(script)
        switchScript = script
    }

    /// Nothing until the user allows user scripts. Matches are narrowed to the hosts the extension is
    /// granted, as Chrome injects only where it has host access, and the Web Store stays excluded.
    /// WebKit filters frames by the patterns; globs are checked by a guard around the code.
    private func makeInstall(_ extensionId: String, context: WKWebExtensionContext, sourcePath: String) -> Install? {
        guard access.states[extensionId]?.allowsUserScripts == true, let current = registrations[extensionId],
              !current.scripts.isEmpty, let makeScript = Self.makeMatchingUserScript else {
            registrations[extensionId]?.built = [:]
            return nil
        }
        func regexes(_ globs: [String]) -> String {
            let patterns = globs.map {
                "^" + NSRegularExpression.escapedPattern(for: $0)
                    .replacingOccurrences(of: "\\*", with: ".*")
                    .replacingOccurrences(of: "\\?", with: ".") + "$"
            }
            return (try? JSONSerialization.data(withJSONObject: patterns)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        let granted = Array(context.grantedPermissionMatchPatterns.keys)
        var scripts: [WKUserScript] = []
        var messagingWorlds: [WKContentWorld] = []
        var built: [String: Built] = [:]
        for script in current.scripts {
            var include: Set<String> = []
            for pattern in (script.matches ?? []).compactMap({ try? WKWebExtension.MatchPattern(string: $0) }) {
                for grant in granted {
                    if grant.matches(pattern) {
                        include.insert(Self.webKitPattern(pattern))
                    } else if pattern.matches(grant) {
                        include.insert(Self.webKitPattern(grant))
                    }
                }
            }
            guard !include.isEmpty else { continue }
            let includePatterns = include.sorted()
            let (world, messaging) = Self.world(script.world, worldId: script.worldId, extensionId: extensionId, worlds: current.worlds)
            if messaging, !messagingWorlds.contains(where: { $0.name == world.name }) { messagingWorlds.append(world) }
            if let cached = current.built[script.id],
               cached.registration == script, cached.include == includePatterns, cached.messaging == messaging {
                built[script.id] = cached
                scripts.append(cached.script)
                continue
            }
            let exclude = (script.excludeMatches ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }.map(Self.webKitPattern)
                + ["*://chromewebstore.google.com/*", "*://chrome.google.com/webstore/*"]

            var source = Self.source(script.js ?? [], extensionDirectory: sourcePath)
            let includeGlobs = script.includeGlobs ?? [], excludeGlobs = script.excludeGlobs ?? []
            if !includeGlobs.isEmpty || !excludeGlobs.isEmpty {
                source = "if (((i, e, u) => (!i.length || i.some(r => new RegExp(r).test(u))) && !e.some(r => new RegExp(r).test(u)))"
                    + "(\(regexes(includeGlobs)), \(regexes(excludeGlobs)), location.href)) {\n\(source)\n}"
            }

            if messaging { source = Self.messagingPrelude(extensionId: extensionId) + source }
            let userScript = makeScript(
                source,
                script.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd,
                !(script.allFrames ?? false),
                includePatterns,
                exclude,
                world
            )
            built[script.id] = Built(registration: script, include: includePatterns, messaging: messaging, script: userScript)
            scripts.append(userScript)
        }
        registrations[extensionId]?.built = built
        guard !scripts.isEmpty else { return nil }
        return Install(scripts: scripts, messagingWorlds: messagingWorlds, allowsPrivateAccess: access.states[extensionId]?.allowsPrivateAccess == true)
    }

    // WebKit's patterns have no `<all_urls>`.
    private static func webKitPattern(_ pattern: WKWebExtension.MatchPattern) -> String {
        pattern.matchesAllURLs ? "*://*/*" : pattern.description
    }

    /// Chrome's `chrome.runtime` for the pages the extension's `externally_connectable` names; nil when it names none.
    private func connectableScript(_ extensionId: String, context: WKWebExtensionContext) -> WKUserScript? {
        if let cached = connectableScripts[extensionId] { return cached }
        let connectable = context.webExtension.manifest["externally_connectable"] as? [String: Any]
        let matches = (connectable?["matches"] as? [String] ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        guard !matches.isEmpty else { return nil }
        let source = Self.externallyConnectableRuntimeSource
        // Without the SPI the script runs in every frame and stands down where WebKit gives no `browser.runtime`.
        let script = Self.makeMatchingUserScript?(source, .atDocumentStart, false, matches.map(Self.webKitPattern), [], .page)
            ?? WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        connectableScripts[extensionId] = script
        return script
    }

    /// Chrome gives a page an extension's `externally_connectable` names `chrome.runtime`, WebKit only
    /// `browser.runtime`: claude.ai's sign-in hands its code to the Claude extension this way. Other
    /// pages keep no `window.chrome`, which sites read as Chrome.
    static let externallyConnectableRuntimeSource = """
    (() => {
      const runtime = globalThis.browser?.runtime;
      if (typeof runtime?.sendMessage !== 'function' || globalThis.chrome?.runtime) return;
      let lastError;
      const chromeRuntime = {
        get lastError() { return lastError; },
        // Chrome's callback form: the trailing function gets the answer, or nothing and lastError.
        sendMessage(...args) {
          const callback = typeof args[args.length - 1] === 'function' ? args.pop() : undefined;
          const sent = runtime.sendMessage(...args);
          if (!callback) return sent;
          sent.then((answer) => callback(answer), (error) => {
            lastError = { message: String(error?.message ?? error) };
            try { callback(); } finally { lastError = undefined; }
          });
        },
        connect: (...args) => runtime.connect(...args),
      };
      globalThis.chrome = Object.assign(globalThis.chrome ?? {}, { runtime: chromeRuntime });
    })();
    """

    /// The world a user script runs in: the page's for MAIN, else the extension's world named by
    /// `worldId`, which takes the default world's configuration when it has none, as in Chrome.
    /// `messaging` when that configuration enables chrome.runtime messaging.
    private static func world(
        _ world: String?, worldId: String?, extensionId: String, worlds: [ExtensionStorage.UserScriptWorld]
    ) -> (world: WKContentWorld, messaging: Bool) {
        guard world != "MAIN" else { return (.page, false) }
        let configuration = worlds.first { ($0.worldId ?? "") == (worldId ?? "") } ?? worlds.first { $0.worldId == nil }
        return (.world(name: worldName(extensionId: extensionId, worldId: worldId)), configuration?.messaging == true)
    }

    /// The world for `chrome.userScripts.execute`, nil when the extension is not loaded.
    func world(_ world: String?, worldId: String?, extensionId: String) -> (world: WKContentWorld, messaging: Bool)? {
        guard runtime(extensionId) != nil else { return nil }
        return Self.world(world, worldId: worldId, extensionId: extensionId, worlds: registrations[extensionId]?.worlds ?? [])
    }

    /// Native recovers the extension and world of a user script message from this name.
    static func worldName(extensionId: String, worldId: String?) -> String {
        "lilo-us-\(extensionId)-\(worldId ?? "")"
    }

    /// The sources of one script, run as one. A file outside the extension's folder, or unreadable, is
    /// skipped.
    static func source(_ sources: [ExtensionStorage.UserScript.Source], extensionDirectory: String) -> String {
        let baseURL = URL(fileURLWithPath: extensionDirectory, isDirectory: true).standardizedFileURL
        return sources.compactMap { js -> String? in
            if let code = js.code { return code }
            guard let file = js.file else { return nil }
            let url = baseURL.appendingPathComponent(file).standardizedFileURL
            guard url.path.hasPrefix(baseURL.path + "/") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n;\n")
    }

    /// The minimal chrome.runtime Chrome exposes to a user script world with messaging: sendMessage
    /// reaches runtime.onUserScriptMessage, and connect opens a port to runtime.onUserScriptConnect.
    static func messagingPrelude(extensionId: String) -> String {
        """
        if (!globalThis.chrome?.runtime?.sendMessage) {
          const handler = window.webkit.messageHandlers.\(UserScriptsBridgeHandler.messageHandlerName);
          const post = (body) => handler.postMessage(body);
          const ports = new Map();
          class Event {
            listeners = new Set();
            addListener(f) { this.listeners.add(f); }
            removeListener(f) { this.listeners.delete(f); }
            hasListener(f) { return this.listeners.has(f); }
            hasListeners() { return this.listeners.size > 0; }
            dispatch(...args) { for (const f of [...this.listeners]) { try { f(...args); } catch (e) { console.error(e); } } }
          }
          globalThis.__liloUserScriptPort = (portId, message, disconnected) => {
            const port = ports.get(portId);
            if (!port) return;
            if (!disconnected) return port.onMessage.dispatch(message, port);
            ports.delete(portId);
            port.connected = false;
            port.onDisconnect.dispatch(port);
          };
          addEventListener("pagehide", () => {
            for (const portId of ports.keys()) post({ kind: "disconnect", portId });
            ports.clear();
          });
          globalThis.chrome = { runtime: {
            id: "\(extensionId)",
            sendMessage(message, ...rest) {
              const callback = typeof rest[rest.length - 1] === "function" ? rest.pop() : undefined;
              const reply = post({ kind: "message", message: message === undefined ? null : message });
              if (!callback) return reply;
              reply.then(callback, () => callback());
            },
            connect(...args) {
              const info = typeof args[0] === "string" ? args[1] : args[0];
              const portId = crypto.randomUUID();
              const port = {
                name: info?.name ?? "", connected: true, onMessage: new Event(), onDisconnect: new Event(),
                postMessage(message) {
                  if (!port.connected) throw new Error("Attempting to use a disconnected port object");
                  post({ kind: "port", portId, message: message === undefined ? null : message });
                },
                disconnect() {
                  if (!port.connected) return;
                  port.connected = false;
                  ports.delete(portId);
                  post({ kind: "disconnect", portId });
                }
              };
              ports.set(portId, port);
              post({ kind: "connect", portId, name: port.name });
              return port;
            }
          } };
        }

        """
    }

    /// `WKUserScript`'s private initializer taking match patterns, so WebKit itself skips the frames a
    /// user script does not match. nil when the SPI is missing: user scripts then never inject.
    static let makeMatchingUserScript: ((String, WKUserScriptInjectionTime, Bool, [String], [String], WKContentWorld) -> WKUserScript)? = {
        let initializer = NSSelectorFromString("_initWithSource:injectionTime:forMainFrameOnly:includeMatchPatternStrings:excludeMatchPatternStrings:associatedURL:contentWorld:")
        let alloc = NSSelectorFromString("alloc")
        guard WKUserScript.instancesRespond(to: initializer),
              let allocMethod = class_getClassMethod(WKUserScript.self, alloc),
              let initImplementation = class_getMethodImplementation(WKUserScript.self, initializer) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, NSString, Int, Bool, NSArray, NSArray, NSURL?, WKContentWorld) -> Unmanaged<WKUserScript>
        let allocate = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        let initialize = unsafeBitCast(initImplementation, to: Init.self)
        return { source, injectionTime, mainFrameOnly, include, exclude, world in
            // `alloc` hands over a +1 instance that the initializer consumes; it returns its own +1.
            initialize(
                allocate(WKUserScript.self, alloc), initializer, source as NSString, injectionTime.rawValue, mainFrameOnly,
                include as NSArray, exclude as NSArray, nil, world
            ).takeRetainedValue()
        }
    }()
}
