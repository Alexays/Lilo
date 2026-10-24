import AppKit
import CoreSpotlight
import OSLog
import Sparkle
import WebKit
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // App-lifetime state shared by every window; spaces outlive any window that shows them.
    let browserContext = BrowserContext()
    /// The window menu actions, external URLs and notifications go to.
    var mainWindowController: MainWindowController? { browserContext.windows.activeWindow }
    private var pendingExternalURLs: [URL] = []
    private var didFinishLaunching = false
    private lazy var littleWindowHotKey = LittleWindowHotKey { [weak self] in self?.newLittleWindow(nil) }
    /// Menus rebuilt each time they open, from the window they act on.
    enum DynamicMenu { case extensions, recentlyClosed, recentlyVisited, spaces, moveToFolder, moveToSpace, terminals, downloads }
    var dynamicMenus: [DynamicMenu: NSMenu] = [:]
    /// Delegate of the other menu bar menus (NSMenu holds its delegate weakly).
    let menuBarImages = MenuBarImageLoader()
    static let developMenuTag = 7001
    /// Mirrors the `showDevelopMenu` setting: the menu bar is built before the settings store opens.
    static let showDevelopMenuKey = "showDevelopMenu"
    /// Nil in Debug and test builds, and in builds without a Sparkle public key: they never check for updates.
    private(set) lazy var updaterController: SPUStandardUpdaterController? = {
        #if DEBUG
        return nil
        #else
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !ProcessInfo.isRunningUnderXCTest else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        #endif
    }()

    static func main() {
        StartupMetrics.mark("main")
        // A write to a peer that went away (socket, pipe, child) must fail with EPIPE, not kill
        // Lilo. Children start with SIGPIPE at its default: Process and the terminal spawn reset it.
        signal(SIGPIPE, SIG_IGN)
        // The launchd default soft limit of 256 open files is far too small for a browser
        // session (SQLite stores, sockets, caches); raise it to the allowed maximum.
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
            limit.rlim_cur = min(rlim_t(OPEN_MAX), limit.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limit)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Lilo draws its own tabs; AppKit's window tabs would stack a second tab bar over the chrome.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Before any WKWebExtensionController exists: extensions serve their pages from chrome-extension://.
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        ThemePreference.applyCachedAtLaunch()
        // The test host never shows the window it would be for.
        if !ProcessInfo.isRunningUnderXCTest { MainWindowController.preloadChromeWebView() }
        StartupMetrics.mark("applicationWillFinishLaunching")
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ProcessInfo.isRunningUnderXCTest else {
            // The test host never shows a window; keep it out of the Dock.
            NSApp.setActivationPolicy(.accessory)
            return
        }
        StartupMetrics.mark("appDidFinishLaunching")
        #if !DEBUG
        // Before any window: the copy that relaunches from Applications owns the profiles.
        if ApplicationsMover.offerMoveIfNeeded() { return }
        #endif
        // Launch benchmark seed (scripts/bench_startup.sh): pages opened as if handed over by another app.
        ProcessInfo.processInfo.environment["LILO_BENCH_SEED_URLS"]?.split(separator: "\n")
            .compactMap { URL(string: String($0)) }.forEach(routeExternalURL)
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(UNNotificationCategory.terminalAttentionCategories.union([NotificationsBridgeHandler.plainCategory]))
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.browserContext.windows.windows.forEach { $0.sendReduceTransparency() } }
        }
        NotificationCenter.default.addObserver(forName: KeyboardShortcuts.didChange, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.browserContext.windows.windows.forEach { $0.sendShortcutKeys() } }
        }

        if mainWindowController == nil {
            browserContext.windows.add(MainWindowController(context: browserContext))
        }
        StartupMetrics.mark("mainWindowControllerReady")
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        StartupMetrics.mark("windowShown")
        // Writes the bundle's custom icon: kept off the path to the first window.
        DispatchQueue.main.async { AppIconPreference.applyCachedAtLaunch() }

        flushPendingExternalURLs()
        didFinishLaunching = true
        Task { await restoreAdditionalWindows() }
        Task {
            guard (try? await browserContext.bootstrap()) != nil else { return }
            applyLittleWindowHotKey()
        }

        NSApp.activate(ignoringOtherApps: true)
        StartupMetrics.mark("appActivated")

        // Build the menu bar off the window-show critical path: ~90 NSMenuItems the first frame never
        // needs. In-window shortcuts go through the controller's NSEvent monitor, not the menu.
        DispatchQueue.main.async { [weak self] in
            self?.setupMainMenu()
            StartupMetrics.mark("mainMenuReady")
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(routeExternalURL) }

    /// Handoff (a page from another device) and Spotlight (a bookmark, identified by its URL).
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        let url: URL? = switch userActivity.activityType {
        case NSUserActivityTypeBrowsingWeb: userActivity.webpageURL
        case CSSearchableItemActionType: (userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(URL.init(string:))
        default: nil
        }
        guard let url else { return false }
        routeExternalURL(url)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !ProcessInfo.isRunningUnderXCTest
    }

    /// Shows the window hidden by a close while a terminal was still running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let window = mainWindowController?.window else { return true }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    /// The first window restores the session; the others reopen once the database is open, behind it.
    private func restoreAdditionalWindows() async {
        guard (try? await browserContext.bootstrap()) != nil else { return }
        let stored = browserContext.startupSnapshot.windows
        guard stored.count > 1 else { return }
        let primary = mainWindowController
        for window in stored.dropFirst() {
            guard let spaceId = window.spaceId ?? browserContext.spaceManager.spaces.first?.id else { continue }
            let controller = MainWindowController(context: browserContext, launch: .space(spaceId, frame: window.frame, opening: .nothing))
            browserContext.windows.add(controller)
            controller.showWindow(nil)
        }
        primary?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        // The window may be minimized, or hidden by a close while a terminal ran: it comes back with what it opens.
        if let window = mainWindowController {
            menu.addItem("New Tab".localized) {
                window.showWindow(nil)
                window.newTab(nil)
            }
            menu.addItem("New Private Space".localized) {
                window.showWindow(nil)
                window.newPrivateSpace(nil)
            }
        }
        menu.add("New Window".localized, #selector(newWindow(_:)))
        return menu
    }

    /// Opens a window on the space the active window shows, with a new blank tab.
    @objc func newWindow(_ sender: Any?) {
        // The Dock menu offers this before bootstrap has built the settings.
        if browserContext.settingsStore?.singleWindow == true, let mainWindowController {
            mainWindowController.newTab(sender)
            return
        }
        guard let spaceId = mainWindowController?.tabManager.currentSpaceId ?? browserContext.spaceManager?.spaces.first?.id else { return }
        browserContext.openWindow(on: spaceId, opening: .newTab)
    }

    /// Opens a Little window on the active window's Space, a browser window first when none is open.
    @objc func newLittleWindow(_ sender: Any?) {
        let owner = mainWindowController
            ?? browserContext.spaceManager?.spaces.first.map { browserContext.openWindow(on: $0.id, opening: .nothing) }
        owner?.openLittleWindow(url: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Follows the `littleWindowHotKey` setting.
    func applyLittleWindowHotKey() {
        littleWindowHotKey.setEnabled(browserContext.settingsStore?.littleWindowHotKey ?? false)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.html, .pdf, .image, .svg, .plainText, .webArchive]
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(routeExternalURL)
    }

    /// Test seam: the confirmation alert shown when quitting would pause downloads (their count)
    /// or stop running terminal commands (their command lines, possibly empty).
    var confirmQuit: (Int, [String]) -> Bool = { downloads, commands in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Lilo?".localized
        var lines: [String] = []
        if !commands.isEmpty {
            let named = commands.filter { !$0.isEmpty }
            var list = named.prefix(3).joined(separator: ", ")
            if named.count > 3 { list += String(format: " and %d more".localized, named.count - 3) }
            let count = commands.count == 1
                ? "A terminal is still running a command".localized
                : String(format: "%d terminals are still running a command".localized, commands.count)
            let stopped = commands.count == 1 ? "It will be stopped.".localized : "They will be stopped.".localized
            lines.append((list.isEmpty ? count : "\(count) (\(list))") + ". " + stopped)
        }
        if downloads > 0 {
            lines.append(downloads == 1
                ? "A download is in progress and will be paused until Lilo opens again.".localized
                : String(format: "%d downloads are in progress and will be paused until Lilo opens again.".localized, downloads))
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Quit".localized)
        alert.addButton(withTitle: "Cancel".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quit decision, separated from the persistence side effect so tests can drive it without UI.
    /// A logout, restart or shutdown never waits on a question: holding it up is worse than the loss.
    func terminationReply(activeDownloads: Int, busyCommands: [String], systemInitiated: Bool) -> NSApplication.TerminateReply {
        guard activeDownloads > 0 || !busyCommands.isEmpty else { return .terminateNow }
        guard systemInitiated || confirmQuit(activeDownloads, busyCommands) else { return .terminateCancel }
        return activeDownloads > 0 ? .terminateLater : .terminateNow
    }

    private var terminationReplyPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Windows AppKit closes on the way out must reopen next launch.
        browserContext.saveWindowsNow()
        browserContext.isQuitting = true
        let controller = mainWindowController
        let manager = browserContext.downloadManager
        // The quit reason of a logout, restart or shutdown names it; a Command-Q carries none.
        let quitReason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
        let reply = terminationReply(
            activeDownloads: manager.activeDownloadCount,
            busyCommands: browserContext.terminalHost.busyCommands,
            systemInitiated: quitReason.map { [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown].contains($0) } ?? false
        )
        if reply == .terminateCancel { browserContext.isQuitting = false }
        let clearsSiteData = browserContext.settingsStore?.clearSiteDataOnQuit == true
        guard reply == .terminateLater || (reply == .terminateNow && clearsSiteData) else { return reply }
        terminationReplyPending = true
        // Bounded: quit proceeds even if a download cancel or a data removal never completes.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.replyToPendingTermination(sender)
        }
        Task { @MainActor in
            if reply == .terminateLater { await manager.pauseAllForQuit() }
            if clearsSiteData { await controller?.clearPersistentSiteData() }
            self.replyToPendingTermination(sender)
        }
        return .terminateLater
    }

    private func replyToPendingTermination(_ sender: NSApplication) {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        browserContext.isTerminating = true
        browserContext.windows.windows.forEach { $0.saveSessionBeforeQuit() }
        browserContext.saveSpaceStatesBeforeQuit()
        browserContext.writeClosedTerminals()
        browserContext.writeTabArchive()
        for profile in browserContext.profileContexts.allContexts { profile.history.flushPendingWrites() }
        // The pty closing at exit only hangs up the login leader, which a shell still starting outlives.
        browserContext.terminalHost.terminateAllForQuit()
        browserContext.agentControl.setEnabled(false)
        // Last write: a quit that dies while saving must still read as unclean on the next launch.
        browserContext.settingsStore?.sessionCleanShutdown = true
        browserContext.dbManager?.closeForShutdown()
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        routeExternalURL(url)
    }

    private func routeExternalURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "file" else { return }
        // Once launched, a link with no browser window open (only a Little window) opens one.
        if didFinishLaunching, mainWindowController == nil, let spaceId = browserContext.spaceManager?.spaces.first?.id {
            browserContext.openWindow(on: spaceId, opening: .nothing)
        }
        if let mainWindowController { mainWindowController.openExternalURL(url) } else { pendingExternalURLs.append(url) }
    }

    private func flushPendingExternalURLs() {
        guard let mainWindowController, !pendingExternalURLs.isEmpty else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        urls.forEach { mainWindowController.openExternalURL($0) }
    }
}

extension AppDelegate: SPUUpdaterDelegate {
    /// The feed's `releases/latest` redirect is cached by URLSession, so a check could keep reading the
    /// previous release's appcast: a fresh query string makes every check reach GitHub.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else { return nil }
        return "\(feed)?check=\(Int(Date().timeIntervalSince1970))"
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        // Extract Sendable primitives off the response before hopping to the main actor (the response
        // and its userInfo dict aren't Sendable). userInfo is set by NotificationsBridgeHandler.create.
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let extensionId = userInfo["extensionId"] as? String
        let notificationId = userInfo["notificationId"] as? String
        let terminalTabId = (userInfo["terminalTabId"] as? String).flatMap(UUID.init(uuidString:))
        let webNotification = userInfo["webNotification"] as? String
        let webTabId = (userInfo["webTabId"] as? String).flatMap(UUID.init(uuidString:))
        let typedReply = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            if let terminalTabId {
                if actionId.hasPrefix(UNNotificationCategory.terminalChoicePrefix) {
                    self.mainWindowController?.answerTerminal(terminalTabId, with: String(actionId.dropFirst(UNNotificationCategory.terminalChoicePrefix.count)))
                } else if actionId == UNNotificationCategory.terminalReply, let typedReply {
                    self.mainWindowController?.answerTerminal(terminalTabId, with: typedReply + "\r")
                }
            }
            if let tabId = terminalTabId ?? webTabId, actionId == UNNotificationDefaultActionIdentifier {
                self.mainWindowController?.revealTab(tabId)
            }
            if let webNotification, actionId == UNNotificationDefaultActionIdentifier {
                self.browserContext.engineFactory.dispatchWebNotificationClick(identifier: webNotification)
            }
            self.handleNotificationResponse(actionId: actionId, extensionId: extensionId, notificationId: notificationId)
            completionHandler()
        }
    }

    /// Fire chrome.notifications.onClicked / onClosed / onButtonClicked for a user interaction,
    /// addressed to the extension that owns the notification. Button taps carry the identifier
    /// `\(buttonActionPrefix)<index>` minted in NotificationsBridgeHandler.create.
    @MainActor
    private func handleNotificationResponse(actionId: String, extensionId: String?, notificationId: String?) {
        guard let extensionId, let notificationId,
              let registry = mainWindowController?.registryOwning(extensionId: extensionId) else { return }
        switch actionId {
        case UNNotificationDefaultActionIdentifier:
            registry.gapEvents.emit("notifications", "onClicked", args: [notificationId], to: [extensionId])
        case UNNotificationDismissActionIdentifier:
            registry.gapEvents.emit("notifications", "onClosed", args: [notificationId, true], to: [extensionId])
        case let id where id.hasPrefix(NotificationsBridgeHandler.buttonActionPrefix):
            guard let index = Int(id.dropFirst(NotificationsBridgeHandler.buttonActionPrefix.count)) else { break }
            registry.gapEvents.emit("notifications", "onButtonClicked", args: [notificationId, index], to: [extensionId])
        default:
            break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension UNUserNotificationCenter {
    /// Authorization is requested on first use; the system prompts once and answers from cache after.
    nonisolated static func requestAuthorizationAndAdd(_ request: sending UNNotificationRequest) {
        Task {
            let center = current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            do {
                try await center.add(request)
            } catch {
                Logger(liloCategory: "Notifications").error("Failed to post notification: \(error, privacy: .public)")
            }
        }
    }
}
