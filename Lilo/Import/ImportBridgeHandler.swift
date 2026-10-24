import AppKit
import Foundation

@MainActor
final class ImportBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = ["scanImportSources", "runImport", "openFullDiskAccessSettings", "closeImport"]

    private weak var bridgeRouter: BridgeRouter?
    private let makeImporter: () -> BrowserImporter
    /// Extensions an import reinstalls open their welcome pages once it has moved on: the hold lasts until the page closes.
    private let holdExtensionTabs: (Bool) -> Void
    private let home: URL
    private let openURL: (URL) -> Bool
    /// Up while the user is in System Settings turning Full Disk Access on.
    private(set) var accessPanel: FullDiskAccessPanel?
    private var sources: [ImportSource] = []
    private var isRunning = false
    /// Bumped when the page closes or finishes, so a scan still in flight never refills `sources`.
    private var scanGeneration = 0
    nonisolated(unsafe) private var activeObserver: Any?

    init(bridgeRouter: BridgeRouter, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         holdExtensionTabs: @escaping (Bool) -> Void, makeImporter: @escaping () -> BrowserImporter) {
        self.bridgeRouter = bridgeRouter
        self.home = home
        self.openURL = openURL
        self.holdExtensionTabs = holdExtensionTabs
        self.makeImporter = makeImporter
        // Granting Full Disk Access happens in System Settings: rescan when the user comes back.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Back in Lilo, the user is done with System Settings: the rescan below tells whether access was granted.
                self?.accessPanel?.close()
                guard let self, !self.isRunning, self.sources.contains(where: \.needsFullDiskAccess) else { return }
                Task { await self.scan() }
            }
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    private func scan() async {
        let generation = scanGeneration
        let home = home
        let found = await Task.detached { BrowserImportScanner.scan(home: home) }.value
        guard generation == scanGeneration else { return }
        // The browser that currently opens links is the one the user lives in: list it first.
        let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        sources = found.filter { $0.bundleId == current } + found.filter { $0.bundleId != current }
        bridgeRouter?.send(event: "importSourcesLoaded", data: ["sources": sources.map(Self.payload)])
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {
        case "scanImportSources":
            await scan()
        case "runImport":
            guard !isRunning else { return BridgeError("Import already running") }
            let selections = (message.payload["selections"] as? [[String: Any]] ?? []).compactMap { raw -> BrowserImporter.Selection? in
                guard let sourceId = raw["sourceId"] as? String, let profileId = raw["profileId"] as? String else { return nil }
                return BrowserImporter.Selection(
                    sourceId: sourceId, profileId: profileId,
                    kinds: Set((raw["kinds"] as? [String] ?? []).compactMap(ImportKind.init(rawValue:))),
                    extensionIds: raw["extensionIds"] as? [String] ?? [])
            }
            isRunning = true
            accessPanel?.close()
            holdExtensionTabs(true)
            let summary = await makeImporter().run(selections, sources: sources) { [weak self] progress in
                self?.bridgeRouter?.send(event: "importProgress", data: [
                    "sourceId": progress.sourceId, "profileId": progress.profileId, "kind": progress.kind.rawValue,
                    "done": progress.done, "total": progress.total
                ])
            }
            isRunning = false
            // The finished page can no longer import, so a later Full Disk Access grant needs no rescan.
            sources = []
            scanGeneration += 1
            bridgeRouter?.send(event: "importFinished", data: ["summary": summary.map { item in
                var data: [String: Any] = ["sourceId": item.sourceId, "profileId": item.profileId, "kind": item.kind.rawValue,
                                           "imported": item.imported]
                if let error = item.error { data["error"] = error }
                return data
            }])
        case "closeImport":
            accessPanel?.close()
            holdExtensionTabs(false)
            sources = []
            scanGeneration += 1
        case "openFullDiskAccessSettings":
            // The Settings app's own anchor first; systems that do not know it take the older pane URL.
            if !openURL(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!) {
                _ = openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            let locked = sources.filter(\.needsFullDiskAccess).map(\.rootURL)
            guard accessPanel == nil, !locked.isEmpty else { break }
            accessPanel = FullDiskAccessPanel(isGranted: { !locked.contains(where: BrowserImportScanner.isDenied) }, onClose: { [weak self] granted in
                guard let self else { return }
                accessPanel = nil
                guard granted else { return }
                // Scanned before Lilo comes forward, so the activation observer finds nothing left to rescan.
                Task {
                    await self.scan()
                    NSApp.activate()
                }
            })
        default:
            break
        }
        return nil
    }

    /// The installed browser's own Dock icon, as a 64 px PNG data URL (cached: rescans resend it).
    private static var icons: [String: String] = [:]

    /// Where a browser LaunchServices never registered (unzipped, copied by hand) is looked for by name.
    private static let appNames = [
        "com.google.Chrome": "Google Chrome", "company.thebrowser.Browser": "Arc", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "com.vivaldi.Vivaldi": "Vivaldi", "company.thebrowser.dia": "Dia",
        "ai.perplexity.comet": "Comet", "com.operasoftware.Opera": "Opera", "org.chromium.Chromium": "Chromium",
        "org.mozilla.firefox": "Firefox", "app.zen-browser.zen": "Zen"
    ]

    private static func icon(bundleId: String) -> String? {
        if let cached = icons[bundleId] { return cached }
        // Beta, Dev, Canary and Nightly builds have identifiers of their own.
        let channel = ["", ".beta", ".Beta", ".dev", ".Dev", ".canary", ".Canary", ".nightly"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId + $0) }.first
        let named = appNames[bundleId].flatMap { name in
            ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: "\($0)/\(name).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let app = channel ?? named,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSWorkspace.shared.icon(forFile: app.path).draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dataURL = "data:image/png;base64," + png.base64EncodedString()
        icons[bundleId] = dataURL
        return dataURL
    }

    private static func payload(_ source: ImportSource) -> [String: Any] {
        [
            "id": source.id, "name": source.name, "family": source.family.rawValue,
            "iconDataURL": icon(bundleId: source.bundleId) ?? "",
            "needsFullDiskAccess": source.needsFullDiskAccess,
            "profiles": source.profiles.map { profile in
                [
                    "id": profile.id, "name": profile.name, "kinds": profile.kinds.map(\.rawValue),
                    "extensions": profile.extensions.map { ["id": $0.id, "name": $0.name] }
                ] as [String: Any]
            }
        ]
    }
}
