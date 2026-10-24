import AppKit

enum BrowserImportScanner {
    /// (id, display name, user data dir under Application Support, Keychain service, bundle id).
    private static let chromium: [(String, String, String, String, String)] = [
        ("chrome", "Chrome", "Google/Chrome", "Chrome Safe Storage", "com.google.Chrome"),
        ("arc", "Arc", "Arc/User Data", "Arc Safe Storage", "company.thebrowser.Browser"),
        ("brave", "Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage", "com.brave.Browser"),
        ("edge", "Edge", "Microsoft Edge", "Microsoft Edge Safe Storage", "com.microsoft.edgemac"),
        ("vivaldi", "Vivaldi", "Vivaldi", "Vivaldi Safe Storage", "com.vivaldi.Vivaldi"),
        ("dia", "Dia", "Dia/User Data", "Dia Safe Storage", "company.thebrowser.dia"),
        ("comet", "Comet", "Comet", "Comet Safe Storage", "ai.perplexity.comet"),
        ("opera", "Opera", "com.operasoftware.Opera", "Opera Safe Storage", "com.operasoftware.Opera"),
        ("chromium", "Chromium", "Chromium", "Chromium Safe Storage", "org.chromium.Chromium")
    ]
    private static let firefox: [(String, String, String, String)] = [
        ("firefox", "Firefox", "Firefox", "org.mozilla.firefox"), ("zen", "Zen", "zen", "app.zen-browser.zen")
    ]

    /// Where a browser LaunchServices never registered (unzipped, copied by hand) is looked for by name.
    private static let appNames = [
        "com.google.Chrome": "Google Chrome", "company.thebrowser.Browser": "Arc", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "com.vivaldi.Vivaldi": "Vivaldi", "company.thebrowser.dia": "Dia",
        "ai.perplexity.comet": "Comet", "com.operasoftware.Opera": "Opera", "org.chromium.Chromium": "Chromium",
        "org.mozilla.firefox": "Firefox", "app.zen-browser.zen": "Zen"
    ]

    static func appURL(bundleId: String) -> URL? {
        // Beta, Dev, Canary and Nightly builds have identifiers of their own.
        let channel = ["", ".beta", ".Beta", ".dev", ".Dev", ".canary", ".Canary", ".nightly"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId + $0) }.first
        return channel ?? appNames[bundleId].flatMap { name in
            ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: "\($0)/\(name).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// Only installed browsers are offered: the folder an uninstalled one left behind, or one a password manager made
    /// for its native helpers, is not a browser in use.
    static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isInstalled: (String) -> Bool = { appURL(bundleId: $0) != nil }
    ) -> [ImportSource] {
        let support = home.appendingPathComponent("Library/Application Support")
        var sources: [ImportSource] = []
        for (id, name, path, service, bundleId) in chromium where isInstalled(bundleId) {
            let root = support.appendingPathComponent(path)
            if isDenied(root) || isDenied(root.appendingPathComponent("Local State")) {
                sources.append(ImportSource(id: id, name: name, family: .chromium, bundleId: bundleId, rootURL: root, keychainService: service,
                                            needsFullDiskAccess: true, profiles: []))
                continue
            }
            // Arc's open tabs are its sidebar, not its session.
            var profiles = chromiumProfiles(root: root, sessions: id != "arc")
            // Arc keeps a profile per space: each profile imports the spaces and favorites it owns.
            if id == "arc", FileManager.default.fileExists(atPath: arcSidebarURL(home: home).path) {
                for index in profiles.indices { profiles[index].kinds.append(.tabs) }
            }
            if !profiles.isEmpty {
                sources.append(ImportSource(id: id, name: name, family: .chromium, bundleId: bundleId, rootURL: root, keychainService: service,
                                            needsFullDiskAccess: false, profiles: profiles))
            }
        }
        let safari = home.appendingPathComponent("Library/Safari")
        let safariDenied = isDenied(safari)
        if safariDenied || FileManager.default.fileExists(atPath: safari.path) {
            var kinds: [ImportKind] = [.bookmarks, .history, .cookies]
            if FileManager.default.fileExists(atPath: safari.appendingPathComponent("LastSession.plist").path) { kinds.insert(.tabs, at: 1) }
            sources.append(ImportSource(id: "safari", name: "Safari", family: .safari, bundleId: "com.apple.Safari", rootURL: safari, keychainService: nil,
                                        needsFullDiskAccess: safariDenied || isDenied(safari.appendingPathComponent("Bookmarks.plist")),
                                        profiles: [ImportProfile(id: "safari", name: "Safari", url: safari, kinds: kinds, extensions: [])]))
        }
        for (id, name, path, bundleId) in firefox where isInstalled(bundleId) {
            let root = support.appendingPathComponent(path)
            if isDenied(root) || isDenied(root.appendingPathComponent("profiles.ini")) {
                sources.append(ImportSource(id: id, name: name, family: .firefox, bundleId: bundleId, rootURL: root, keychainService: nil,
                                            needsFullDiskAccess: true, profiles: []))
                continue
            }
            let profiles = firefoxProfiles(root: root)
            if !profiles.isEmpty {
                sources.append(ImportSource(id: id, name: name, family: .firefox, bundleId: bundleId, rootURL: root, keychainService: nil,
                                            needsFullDiskAccess: false, profiles: profiles))
            }
        }
        return sources
    }

    /// True when `url` exists but macOS refuses to open it: EPERM without Full Disk Access, EACCES from file permissions.
    /// A missing file is ENOENT, never a denial.
    static func isDenied(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        if fd >= 0 { close(fd); return false }
        return errno == EPERM || errno == EACCES
    }

    static func arcSidebarURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    }

    static func safariCookiesURL(home: URL) -> URL {
        let container = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        return FileManager.default.fileExists(atPath: container.path) ? container : home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
    }

    private static func chromiumProfiles(root: URL, sessions: Bool) -> [ImportProfile] {
        let fm = FileManager.default
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] {
            names = cache.compactMapValues { $0["name"] as? String }
        }
        // Without a profile list, the folders Chromium names its profiles; Opera keeps its single profile at the root.
        var dirs = names.keys.sorted()
        if dirs.isEmpty {
            dirs = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
            if dirs.isEmpty { dirs = [""] }
        }
        return dirs.compactMap { dirName in
            let url = dirName.isEmpty ? root : root.appendingPathComponent(dirName)
            var kinds: [ImportKind] = []
            if fm.fileExists(atPath: url.appendingPathComponent("Bookmarks").path) { kinds.append(.bookmarks) }
            if sessions, ChromiumSession.file(in: url) != nil { kinds.append(.tabs) }
            if fm.fileExists(atPath: url.appendingPathComponent("History").path) { kinds.append(.history) }
            if fm.fileExists(atPath: url.appendingPathComponent("Network/Cookies").path) || fm.fileExists(atPath: url.appendingPathComponent("Cookies").path) {
                kinds.append(.cookies)
            }
            let extensions = ChromiumReader.extensions(in: url)
            if !extensions.isEmpty { kinds.append(.extensions) }
            guard !kinds.isEmpty else { return nil }
            return ImportProfile(id: dirName.isEmpty ? "Default" : dirName, name: names[dirName] ?? "Default", url: url, kinds: kinds, extensions: extensions)
        }
    }

    private static func firefoxProfiles(root: URL) -> [ImportProfile] {
        guard let ini = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
        var profiles: [ImportProfile] = []
        var section: [String: String] = [:]
        func flush() {
            defer { section = [:] }
            guard let path = section["Path"] else { return }
            let url = section["IsRelative"] == "0" ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            var kinds: [ImportKind] = []
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("places.sqlite").path) { kinds += [.bookmarks, .history] }
            let session = ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4"].contains {
                FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
            }
            if session { kinds.append(.tabs) }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("cookies.sqlite").path) { kinds.append(.cookies) }
            if !kinds.isEmpty {
                profiles.append(ImportProfile(id: url.lastPathComponent, name: section["Name"] ?? url.lastPathComponent, url: url, kinds: kinds, extensions: []))
            }
        }
        for line in ini.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("[") {
                flush()
                if !line.hasPrefix("[Profile") { section = ["skip": "1"] }
            } else if section["skip"] == nil, let eq = line.firstIndex(of: "=") {
                section[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        flush()
        return profiles
    }
}
