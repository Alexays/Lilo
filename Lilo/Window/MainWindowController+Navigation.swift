// Favicon, tab delegate, navigation.

import AppKit
import CryptoKit
import OSLog
import WebKit

// MARK: - Favicon

extension MainWindowController {
    @discardableResult
    func updateRuntimeTab(id: UUID, mutate: (inout Tab) -> Void) -> Tab? {
        guard let (old, new) = context.browserState.updateTab(id: id, mutate: mutate) else { return nil }
        if isVisibleTab(id) {
            tabManager.noteTabUpdated(old: old, new: new)
        }
        // Only windows showing the space get the favicon patch: the others' next full state of it must carry favicons again.
        if new.faviconDataURL != old.faviconDataURL, let spaceId = context.browserState.owningSpaceId(forTab: id) {
            for window in context.windows.windows where window.tabManager.currentSpaceId != spaceId {
                window.chromeFaviconSyncedSpaceIds.remove(spaceId)
            }
        }
        return new
    }

    func updateTabFavicon(faviconDataURL: String?, dominantColor color: String?, forTabId tabId: UUID) {
        guard let faviconDataURL else { return }
        // favicon is a durable field (not part of the runtime overlay), so the O(1) durable lookup
        // is equivalent to the full projected read here without materializing the whole sidebar.
        guard context.browserState.durableTab(for: tabId)?.tab.faviconDataURL != faviconDataURL else { return }
        guard let updatedTab = updateRuntimeTab(id: tabId, mutate: { tab in
            tab.faviconDataURL = faviconDataURL
            tab.faviconDominantColor = color
            // The home page's icon follows its site: signing in can land on another path of the same host.
            let host = tab.url?.host?.lowercased()
            if tab.matchesHomeURL(tab.url) || (host != nil && host == tab.homeURL?.host?.lowercased()) {
                tab.homeFaviconDataURL = faviconDataURL
                tab.homeFaviconDominantColor = color
            }
        }) else { return }
        enqueueVisibleTabUpdate(updatedTab, includeFavicon: true)
        profileContext?.sessionPersistence?.scheduleSave()
    }
}

// MARK: - WKWebViewTab.Delegate

extension MainWindowController: WKWebViewTab.Delegate {
    func tab(_ tab: WKWebViewTab, didNavigate event: WKWebViewTab.WebNavigationEvent) {
        let eventURL: URL?
        switch event {
        case .started(let url):
            eventURL = url
            readerModeTabs.remove(tab.id)
        case .committed(let url), .finished(let url):
            eventURL = url
        case .failed(let url, _):
            eventURL = url
        }

        switch event {
        case .committed:
            let committedURL = eventURL ?? tab.currentURL
            tab.zoomSettings = WKWebViewTab.ZoomSettings()
            profileContext?.extensions.access.tabDidCommitNavigation(tab.id, url: committedURL)
            // An agent tab stays at the zoom the agent measures with, whatever this window's profile keeps for the site.
            if !tab.isAgentControlled {
                profileContext?.zoom.applyZoom(to: tab, forURL: committedURL, default: context.settingsStore.defaultZoom)
            }
            if let scheme = committedURL?.scheme, let host = committedURL?.host {
                denyPermissionRequests(forTab: tab.id, notFromOrigin: PermissionOriginKey.build(scheme: scheme, host: host, port: committedURL?.port ?? 0))
            }
        case .failed(_, let error):
            // Private spaces never go through an extension's proxy.
            if let profile = profileContext, !tab.isPrivateBrowsing { context.engineFactory.reportProxyFailure(error, registry: profile.extensions) }
        case .started, .finished: break
        }

        let updatedTab = updateRuntimeTab(id: tab.id) { t in
            let resolvedURL = eventURL ?? tab.currentURL ?? t.url
            t.url = resolvedURL
            t.title = self.resolvedTabTitle(currentTitle: tab.currentTitle, url: resolvedURL, existingTitle: t.title)
            if t.matchesHomeURL(resolvedURL) {
                t.homeTitle = t.title
            }
            t.isLoading = tab.isLoading
            t.canGoBack = tab.canGoBack
            t.canGoForward = tab.canGoForward

            switch event {
            case .started, .committed, .finished:
                if case .started = event { t.estimatedProgress = 0 }
                (t.hasNavigationError, t.navigationErrorCode) = (false, 0)
                (t.navigationErrorDomain, t.navigationErrorDescription, t.navigationErrorURL) = ("", "", "")
            case .failed(let url, let error):
                let nsError = error as NSError
                let isError = !WKWebViewTab.shouldIgnoreNavigationFailure(error)
                t.hasNavigationError = isError
                t.navigationErrorCode = isError ? nsError.code : 0
                t.navigationErrorDomain = isError ? nsError.domain : ""
                t.navigationErrorDescription = isError ? nsError.localizedDescription : ""
                t.navigationErrorURL = isError ? (url ?? resolvedURL)?.absoluteString ?? "" : ""
            }
        }
        // Side effect, kept out of the mutate closure above: the closure must stay a pure
        // field mutation the store can run without observable effects.
        switch event {
        case .committed, .finished, .failed:
            tabManager.engineHost.markRestorationFinished(for: tab.id)
            // URL and title are durable: without a save here a crash would restore the tab at the page
            // it was last activated on (debounced, and skipped when nothing durable changed).
            profileContext?.sessionPersistence?.scheduleSave()
            if tab.id == tabManager.activeOpenTabId { publishActiveTab() }
        case .started:
            break
        }
        if let updatedTab, isVisibleTab(tab.id) {
            enqueueVisibleTabUpdate(updatedTab)
        }

        if case .finished = event {
            // Private-space, protected-folder and unresolvable-space visits leave no trace (no history, no onVisited). Check the visiting tab's
            // own space, which may be a background one; a popup's visit counts as its opener's.
            let visitingTab = updatedTab ?? pagePopups[tab.id].flatMap { tabManager.tab(for: $0.openerTabId) }
            let isPublicSpace = (visitingTab?.spaceId ?? littleWindows[tab.id]?.spaceId)
                .flatMap { context.spaceManager?.space(with: $0) }.map { !$0.isPrivate } ?? false
            let isProtected = visitingTab.flatMap { tabManager.protectingFolder(of: $0) } != nil
            if isPublicSpace, !isProtected, let url = tab.currentURL, !url.absoluteString.isEmpty,
               url.scheme == "https" || url.scheme == "http" {
                // A page a terminal's link opened in a peek remembers which terminal: folder and branch.
                let openedFrom = pagePopups[tab.id].flatMap { tabManager.tab(for: $0.openerTabId) }
                    .flatMap { opener -> String? in
                        guard opener.kind == .terminal else { return nil }
                        let folder = opener.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                        return [folder, opener.gitBranch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    }
                profileContext?.history.scheduleRecordVisit(url: url.absoluteString, title: tab.currentTitle ?? "", openedFrom: openedFrom)
            }
        }
    }

    // Even for non-visible tabs (other spaces / not-yet-registered): the favicon is persisted to the
    // store and shown when the tab becomes visible. updateTabFavicon only emits a live UI event for visible tabs.
    func tab(_ tab: WKWebViewTab, offersIcons icons: [WKWebViewTab.LinkIcon]) {
        faviconCoordinator.extract(from: tab, icons: icons)
    }

    func tab(_ tab: WKWebViewTab, didUpdateTitle title: String?) {
        let updatedTab = updateRuntimeTab(id: tab.id) { t in
            t.title = self.resolvedTabTitle(currentTitle: title, url: tab.currentURL, existingTitle: t.title)
            if t.matchesHomeURL(tab.currentURL ?? t.url) {
                t.homeTitle = t.title
            }
        }
        if let updatedTab { enqueueVisibleTabUpdate(updatedTab) }
        if tab.id == tabManager.activeOpenTabId { publishActiveTab() }
    }

    func tab(_ tab: WKWebViewTab, didUpdateURL url: URL?) {
        var shouldRefreshFavicon = false
        let updatedTab = updateRuntimeTab(id: tab.id) { t in
            let previousURL = t.url
            let resolvedURL = url ?? tab.currentURL ?? t.url
            if resolvedURL == nil || previousURL?.host?.lowercased() != resolvedURL?.host?.lowercased() {
                t.faviconDataURL = nil
                t.faviconDominantColor = nil
                shouldRefreshFavicon = resolvedURL != nil
            }
            t.url = resolvedURL
            if t.title.isEmpty || t.title == Tab.placeholderTitle {
                t.title = Tab.fallbackTitle(for: resolvedURL)
            }
        }
        if let updatedTab {
            // Favicon was cleared above on host change: ship it so the UI drops the stale icon.
            enqueueVisibleTabUpdate(updatedTab, includeFavicon: shouldRefreshFavicon)

            if isVisibleTab(tab.id),
               shouldRefreshFavicon || (updatedTab.faviconDataURL == nil && !updatedTab.isLoading) {
                faviconCoordinator.applyCached(from: tab)
            }
        }
    }

    func tab(
        _ tab: WKWebViewTab, authenticateProxy challenge: URLAuthenticationChallenge,
        completion: @escaping @MainActor (_ answer: (URLSession.AuthChallengeDisposition, URLCredential?)?) -> Void
    ) {
        guard let registry = profileContext?.extensions, registry.hasLoadedExtensions else { return completion(nil) }
        context.engineFactory.authenticateProxy(
            challenge, url: tab.currentURL, tab: tabManager.engineHost.tabAdapter(for: tab.id), registry: registry, completion: completion
        )
    }

    func tab(_ tab: WKWebViewTab, shouldAllowInsecureServerTrust trust: SecTrust, forHost host: String, port: Int) -> Bool {
        let key = "\(host.lowercased()):\(port)"
        guard let expected = insecureTrustExceptions[key], let fingerprint = Self.leafCertificateFingerprint(trust) else { return false }
        // Recorded without a certificate in hand: bind the exception to the first one presented.
        if expected.isEmpty {
            insecureTrustExceptions[key] = fingerprint
            return true
        }
        return expected == fingerprint
    }

    /// Records a user-approved certificate exception for `host` (on the failed URL's port, pinned to
    /// the certificate that failed) and reloads so the page can load.
    func allowInsecureTrust(forHost host: String) {
        let normalized = host.lowercased()
        guard !normalized.isEmpty, let activeTab = tabManager.activeTab else { return }
        let failedURL = URL(string: activeTab.navigationErrorURL) ?? activeTab.url
        let trust = tabManager.activeEngineTab?.lastServerTrust
        insecureTrustExceptions["\(normalized):\(failedURL?.port ?? 443)"] = trust.flatMap(Self.leafCertificateFingerprint) ?? ""
        tabManager.reloadActiveTab()
    }

    static func leafCertificateFingerprint(_ trust: SecTrust) -> String? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }

    func tab(_ tab: WKWebViewTab, didUpdateLoading isLoading: Bool) {
        updateAndEmit(tab.id) { t in t.isLoading = isLoading }
    }

    func tab(_ tab: WKWebViewTab, didUpdateProgress progress: Double) {
        let progressUpdateStart = DispatchTime.now().uptimeNanoseconds
        defer {
            StartupMetrics.recordDurationSample("progressUpdate", startUptime: progressUpdateStart)
            StartupMetrics.recordProgressUpdateSample()
        }
        // Only the address bar draws progress, and only the active tab's: a background load keeps just
        // its final value, and activation reads the live one off the engine.
        guard let active = tabManager.activeTab, tab.id == active.id else {
            PerfSignposts.energy.emitEvent("progress", "dropped")
            if progress >= 1 { updateRuntimeTab(id: tab.id) { t in t.estimatedProgress = progress } }
            return
        }
        // The bar cannot show steps finer than this; a load's start and end always ship.
        let fineStep = progress > 0 && progress < 1 && abs(progress - active.estimatedProgress) < 0.05
        PerfSignposts.energy.emitEvent("progress", "\(fineStep ? "dropped" : "sent")")
        guard !fineStep else { return }
        updateAndEmit(tab.id) { t in t.estimatedProgress = progress }
    }

    func tab(_ tab: WKWebViewTab, didUpdateCanGoBack canGoBack: Bool) {
        updateAndEmit(tab.id) { t in t.canGoBack = canGoBack }
    }

    func tab(_ tab: WKWebViewTab, didUpdateCanGoForward canGoForward: Bool) {
        updateAndEmit(tab.id) { t in t.canGoForward = canGoForward }
    }

    func tab(_ tab: WKWebViewTab, didCreateNewTab url: URL?, inBackground: Bool) {
        // An agent's new tab joins its folder in the background: the user's shown tab stays put.
        guard !tab.isAgentControlled else { return context.agentControl.openTab(from: tab, url: url) }
        // A Little window's new tab is another Little window, not a tab of the window behind.
        if littleWindows[tab.id] != nil {
            openLittleWindow(url: url)
            return
        }
        guard let created = createTabStateFirst(url: url, activate: !inBackground, opener: tab.id), let url else { return }
        reportCreatedNavigationTarget(from: tab.id, to: created.id, url: url)
    }

    /// `webNavigation.onCreatedNavigationTarget` for a page that opened `url` in a new tab.
    private func reportCreatedNavigationTarget(from sourceId: UUID, to tabId: UUID, url: URL) {
        guard let registry = profileContext?.extensions else { return }
        let ids = registry.gapEvents.listeners(
            among: registry.extensionIds(withPermission: "webNavigation"), namespace: "webNavigation", event: "onCreatedNavigationTarget"
        )
        guard !ids.isEmpty, let sourceAdapter = tabManager.tabAdapter(for: sourceId), let targetAdapter = tabManager.tabAdapter(for: tabId) else { return }
        let timeStamp = Date().timeIntervalSince1970 * 1000
        registry.emitPositioned("webNavigation", "onCreatedNavigationTarget", to: ids) { extensionId in
            guard let source = registry.tabPosition(of: sourceAdapter, extensionId: extensionId),
                  let target = registry.tabPosition(of: targetAdapter, extensionId: extensionId) else { return nil }
            return ["source": source, "tab": target, "url": url.absoluteString, "timeStamp": timeStamp]
        }
    }

    func tab(_ tab: WKWebViewTab, openLinkInNewPrivateSpace url: URL) {
        do {
            // createSpace activates the new space synchronously (through switchToSpace),
            // so the tab below lands in it.
            try createSpace(name: "Private", icon: "🕶️", color: "#5865f2", isPrivate: true, targetProfileId: nil)
            createTabStateFirst(url: url, activate: true)
        } catch {
            Self.logger.error("open link in new private space failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    func tab(_ tab: WKWebViewTab, openLinkInNewWindow url: URL) {
        guard let spaceId = tabManager.currentSpaceId else { return }
        context.openWindow(on: spaceId, opening: .urls([url]))
    }
    var prefersSingleWindow: Bool { context.settingsStore.singleWindow }
    func tabDidRequestClose(_ tab: WKWebViewTab) {
        if tab.id == sidePanel.engineId { return sidePanel.closePanel() }
        if let little = littleWindows[tab.id] { return little.window.close() }
        if let popup = pagePopups[tab.id] { popup.close() } else { closeTabStateFirst(id: tab.id) }
    }

    func tab(_ tab: WKWebViewTab, didStartDownload download: WKDownload) {
        context.downloadManager.startDownload(download, privateSpaceId: privateSpaceId(of: tab))
        // A target=_blank download link leaves a tab that never shows a page: close it (the download outlives the web view), deferred so
        // the web view is not torn down inside WebKit's didBecomeDownload callback.
        guard !tab.hasCommittedContent else { return }
        let tabId = tab.id
        DispatchQueue.main.async { [weak self] in
            if let little = self?.littleWindows[tabId] { return little.window.close() }
            if let popup = self?.pagePopups[tabId] { popup.close() } else { self?.closeTabStateFirst(id: tabId, undoable: false) }
        }
    }

    func tab(_ tab: WKWebViewTab, requestPermission type: String, forOrigin origin: String, completion: @escaping (Bool) -> Void) {
        if let storedDecision = storedPermissionDecision(type: type, origin: origin, isPrivate: tab.isPrivateBrowsing) {
            completion(storedDecision)
            return
        }
        if context.settingsStore.refusesPermissionRequests(type) { return completion(false) }

        let remember: (Bool) -> Void = { [weak self] granted in
            completion(granted)
            guard let self, !tab.isPrivateBrowsing else { return }
            context.sitePermissionStore.upsert(origin: origin, type: type, granted: granted)
            bridgeRouter.sendSitePermissionsLoaded(from: context.sitePermissionStore)
        }
        if let little = littleWindows[tab.id] {
            return PagePopupController.askPermission(type, for: tab, in: little.window, completion: remember)
        }
        guard let popup = pagePopups[tab.id] else {
            return enqueuePermissionRequest(tabId: tab.id, type: type, origin: origin, completion: completion)
        }
        // A popup window asks in a sheet of its own; a peek through its opener tab's prompt, drawn over it.
        let asked = popup.askPermission(type, completion: remember)
        if !asked { enqueuePermissionRequest(tabId: popup.openerTabId, type: type, origin: origin, completion: completion) }
    }

    func tab(_ tab: WKWebViewTab, didHoverLink href: String?) {
        // The link readout sits at the bottom of the browser's content, not of a popup.
        if pagePopups[tab.id] == nil, littleWindows[tab.id] == nil { sendHoveredLink(href ?? "") }
        // A hovered link is the likeliest next navigation: warm its connection so the click skips
        // DNS and the TLS handshake. Once per host; the page's own host is already connected.
        if let href, let url = URL(string: href), url.scheme == "https" || url.scheme == "http",
           let host = url.host, host != lastPreconnectedHost, host != tab.currentURL?.host {
            lastPreconnectedHost = host
            tab.preconnect(to: url)
        }
    }

    func sendHoveredLink(_ href: String) {
        guard href != lastHoveredLinkHref else { return }
        lastHoveredLinkHref = href
        bridgeRouter.send(event: "hoveredLinkChanged", data: ["href": href])
    }

    /// `host` is what the content blocker's allowed sites hold; `site`, the registrable domain a repeat is told by.
    func tab(_ tab: WKWebViewTab, didChangeResponsive responsive: Bool) {
        guard pagePopups[tab.id] == nil, littleWindows[tab.id] == nil else { return }
        let host = tab.currentURL?.host()?.lowercased() ?? ""
        bridgeRouter.send(event: "pageResponsivenessChanged", data: [
            "tabId": tab.id.uuidString,
            "responsive": responsive,
            "host": host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
            "site": host.isEmpty ? "" : CookiesBridgeHandler.registrableDomain(of: host)
        ])
    }

    /// Marks the tab as waiting for the user, like a terminal waiting for an answer.
    func tab(_ tab: WKWebViewTab, didUpdateAwaitingDialog isAwaiting: Bool) {
        enqueueVisibleTabUpdate(updateRuntimeTab(id: tab.id) { $0.awaitingInputSince = isAwaiting ? Date() : nil })
    }

    func tab(_ tab: WKWebViewTab, didUpdateTrackersBlocked count: Int) {
        guard tabManager.activeEngineTab === tab else { return }  // badge tracks the active tab only
        bridgeRouter.send(event: "trackersBlockedChanged", data: ["count": count])
    }

    func tab(_ tab: WKWebViewTab, storedPermissionDecisionFor type: String, origin: String) -> Bool? {
        storedPermissionDecision(type: type, origin: origin, isPrivate: tab.isPrivateBrowsing)
    }

    func tab(_ tab: WKWebViewTab, allowsJavaScriptAt url: URL) -> Bool {
        guard let profile = profileContext else { return true }
        return context.engineFactory.contentSettingsHandler.extensionSetting(
            "javascript", primary: url, settings: profile.extensionSettings, registry: profile.extensions, isPrivate: tab.isPrivateBrowsing
        ) != "block"
    }

    /// The user's stored decision, unless an extension's chrome.contentSettings rule takes precedence
    /// ("ask" prompts whatever the user chose before). Camera and microphone are decided together.
    func storedPermissionDecision(type: String, origin: String, isPrivate: Bool) -> Bool? {
        let decisions: [Bool?] = (type == "camera and microphone" ? ["camera", "microphone"] : [type]).map { type in
            let rule = profileContext.flatMap { profile in
                URL(string: origin).flatMap {
                    context.engineFactory.contentSettingsHandler.extensionSetting(
                        type, primary: $0, settings: profile.extensionSettings, registry: profile.extensions, isPrivate: isPrivate
                    )
                }
            }
            switch rule {
            case "allow": return true
            case "block": return false
            case "ask": return nil
            default: return context.sitePermissionStore.decision(forOrigin: origin, type: type)
            }
        }
        if decisions.contains(false) { return false }
        return decisions.allSatisfy { $0 == true } ? true : nil
    }

    func tabRequestsForeground(_ tab: WKWebViewTab) {
        // An agent never brings Lilo forward over what the user is doing.
        guard !tab.isAgentControlled else { return }
        if let popup = pagePopups[tab.id] { return focusPagePopup(popup) }
        if let little = littleWindows[tab.id] {
            little.window.makeKeyAndOrderFront(nil)
            return NSApp.activate()
        }
        activateTabStateFirst(id: tab.id)
        window?.makeKeyAndOrderFront(nil)
        // The request usually arrives while another app is frontmost (a PiP return click, a
        // notification-driven focus): ordering the window front within an inactive app isn't visible.
        NSApp.activate()
    }

    func tab(_ tab: WKWebViewTab, saveData data: Data, suggestedFilename: String, mimeType: String, originatingURL: URL) {
        context.downloadManager.saveData(
            data, suggestedFilename: suggestedFilename, mimeType: mimeType, originatingURL: originatingURL,
            privateSpaceId: privateSpaceId(of: tab)
        )
    }

    /// The tab's space id when it browses privately, so its downloads can be forgotten with the space.
    private func privateSpaceId(of tab: WKWebViewTab) -> UUID? {
        guard tab.isPrivateBrowsing else { return nil }
        return tabManager.tab(for: tab.id)?.spaceId ?? tabManager.currentSpaceId
    }

    func tabRequestsBookmark(_ tab: WKWebViewTab) {
        // Bookmarks are tabs: a popup's page becomes the active tab first.
        pagePopups[tab.id]?.openAsTab()
        littleWindows[tab.id].map { moveLittleWindow($0, toSpace: $0.spaceId) }
        bookmarkCurrentTab(nil)
    }

    func tab(_ tab: WKWebViewTab, launchExternalURL url: URL, fromPage pageURL: URL?) {
        let origin: String = {
            guard let scheme = pageURL?.scheme, let host = pageURL?.host else { return "unknown" }
            // URL.port is nil for default-port URLs; PermissionOriginKey treats 0 as "no port",
            // so default-port pages produce the portless key their stored decisions use.
            return PermissionOriginKey.build(scheme: scheme, host: host, port: pageURL?.port ?? 0)
        }()
        let type = "external-scheme"
        if let decision = context.sitePermissionStore.decision(forOrigin: origin, type: type) {
            if decision { NSWorkspace.shared.open(url) }
            return
        }
        // The prompt is a sheet on this window; a background tab has no surface to ask from.
        guard isVisibleTab(tab.id), let window else { return }
        let appName = NSWorkspace.shared.urlForApplication(toOpen: url)?.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = appName.map { String(format: "Open this link in %@?".localized, $0) }
            ?? "Open this link in another app?".localized
        alert.informativeText = String(format: "%@ wants to open an external app.".localized, origin)
        alert.showsSuppressionButton = !tab.isPrivateBrowsing
        alert.suppressionButton?.title = "Always allow for this site".localized
        alert.addButton(withTitle: "Open".localized)
        alert.addButton(withTitle: "Cancel".localized)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let open = response == .alertFirstButtonReturn
            if alert.suppressionButton?.state == .on, origin != "unknown", !tab.isPrivateBrowsing {
                context.sitePermissionStore.upsert(origin: origin, type: type, granted: open)
                bridgeRouter.sendSitePermissionsLoaded(from: context.sitePermissionStore)
            }
            if open { NSWorkspace.shared.open(url) }
        }
    }

    func requestSitePermission(type: String, origin: String, webView: WKWebView?, completion: @escaping (Bool) -> Void) {
        let isPrivate = webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
        if let storedDecision = storedPermissionDecision(type: type, origin: origin, isPrivate: isPrivate) {
            completion(storedDecision)
            return
        }
        if context.settingsStore.refusesPermissionRequests(type) { return completion(false) }
        if (webView?.uiDelegate as? WKWebViewTab)?.agentDialogHandler?("\(type) permission for \(origin) denied: agent tabs never ask the user") == true {
            return completion(false)
        }

        // The prompt lives in its tab's chrome, so an unattributable request has nowhere to show.
        guard let tabId = tabId(owning: webView) else {
            completion(false)
            return
        }
        enqueuePermissionRequest(tabId: tabId, type: type, origin: origin, completion: completion)
    }

    private func tabId(owning webView: WKWebView?) -> UUID? {
        guard let webView else { return nil }
        return tabManager.engineTab(forWebView: webView)?.id
    }

    func tab(_ tab: WKWebViewTab, didUpdateAudioPlaying isPlaying: Bool) {
        updateAndEmit(tab.id) { t in
            t.isAudioPlaying = isPlaying
            t.lastAudioStoppedAt = isPlaying ? nil : Date()
            if isPlaying { t.pausedFromCardAt = nil }
        }
        mediaPlaybackChanged(tab, isPlaying: isPlaying)
    }

    func tab(_ tab: WKWebViewTab, didUpdateFormDirty isDirty: Bool) {
        updateAndEmit(tab.id) { $0.hasUnsavedFormData = isDirty }
    }

    func tab(_ tab: WKWebViewTab, didUpdatePermissionUsage usage: WKWebViewTab.WebPermissionUsageState) {
        let now = Date()
        updateAndEmit(tab.id) { t in
            let wasCapturing = t.isMicrophoneActive || t.isCameraActive || t.isScreenSharing
            let isCapturing = usage.usesMicrophone || usage.usesCamera || usage.usesScreen
            t.isMicrophoneActive = usage.usesMicrophone
            t.isMicrophoneMuted = usage.isMicrophoneMuted
            t.isCameraActive = usage.usesCamera
            t.isScreenSharing = usage.usesScreen
            // Stamp the on-to-off edge to start the capture retention grace (mirrors lastAudioStoppedAt).
            if isCapturing {
                t.lastCaptureStoppedAt = nil
            } else if wasCapturing {
                t.lastCaptureStoppedAt = now
            }
        }
    }

    /// Emits only on a real change: KVO re-reports values `didNavigate` already applied (loading,
    /// back/forward), and each patch rewrites the chrome's sidebar state.
    func updateAndEmit(_ id: UUID, _ mutate: (inout Tab) -> Void) {
        guard let (old, new) = context.browserState.updateTab(id: id, mutate: mutate), old != new else { return }
        if context.mediaTabs[id] != nil { context.mediaActivityChanged() }
        if isVisibleTab(new.id) {
            tabManager.noteTabUpdated(old: old, new: new)
        }
        enqueueVisibleTabUpdate(new)
    }
}

extension MainWindowController {
    func resolvedTabTitle(currentTitle: String?, url: URL?, existingTitle: String) -> String {
        let title = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, url != nil || (!existingTitle.isEmpty && existingTitle != Tab.placeholderTitle) { return title }
        return (existingTitle.isEmpty || existingTitle == Tab.placeholderTitle) ? Tab.fallbackTitle(for: url) : existingTitle
    }
}

// MARK: - WKNavigationDelegate

extension MainWindowController: WKNavigationDelegate {
    /// The chrome web view holds the bridge to the whole browser: it only ever shows Lilo's own UI.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let devServer = chromeUIDevServerURL()
        let isOwnUI = url?.scheme == ChromeUISchemeHandler.scheme
            || devServer.map { url?.scheme == $0.scheme && url?.host == $0.host && url?.port == $0.port } == true
        if !isOwnUI { Self.logger.error("refused a chrome web view navigation away from Lilo's UI") }
        decisionHandler(isOwnUI ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView == chromeWebView else { return }
        StartupMetrics.mark("chromeNavigationStarted")
        Task { @MainActor [weak self] in
            self?.startupNonCriticalUICoordinator.markNavigationStarted()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView == chromeWebView else { return }; StartupMetrics.mark("chromeNavigationCommitted")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView == chromeWebView else { return }; StartupMetrics.mark("chromeNavigationFinished")
    }

    /// The chrome overlay is the entire browser UI: losing its WebContent process (the app's own
    /// lifecycle trimming raises memory pressure) would otherwise leave a permanently blank window.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView == chromeWebView else { return }
        let now = Date()
        chromeReloadAttempts.removeAll { now.timeIntervalSince($0) > Self.chromeReloadAttemptWindow }
        guard chromeReloadAttempts.count < Self.chromeReloadMaxAttempts else {
            Self.logger.fault("chrome web content process died \(Self.chromeReloadMaxAttempts, privacy: .public) times within \(Int(Self.chromeReloadAttemptWindow), privacy: .public)s; giving up on reload")
            presentChromeRecoveryAlert()
            return
        }
        chromeReloadAttempts.append(now)
        Self.logger.error("chrome web content process terminated; reloading chrome UI (attempt \(self.chromeReloadAttempts.count, privacy: .public))")
        reloadChromeUI()
    }

    /// The reloaded chrome re-runs the bootstrap ready handshake (installChromeBootstrapScript's
    /// user script posts `ready` on every main-frame load); resetting these lets handleChromeReady
    /// re-dispatch the full initial state exactly like a first boot.
    func reloadChromeUI() {
        didReceiveChromeReady = false
        hasDispatchedChromeInitialState = false
        bridgeRouter?.resetInFlightCall()
        chromeWebView.load(URLRequest(url: chromeUIDevServerURL() ?? ChromeUISchemeHandler.indexURL))
    }

    /// Last resort once automatic reloads are exhausted: without the overlay the window is blank,
    /// so the user chooses between one more reload and quitting.
    func presentChromeRecoveryAlert() {
        // Nobody to ask without a window or under the test host; one more reload is harmless.
        guard let window, !ProcessInfo.isRunningUnderXCTest else {
            reloadChromeUI()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The browser interface stopped responding.".localized
        alert.informativeText = "Lilo can reload its interface; your tabs are kept.".localized
        alert.addButton(withTitle: "Reload UI".localized)
        alert.addButton(withTitle: "Quit".localized)
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn {
                NSApp.terminate(nil)
                return
            }
            self?.chromeReloadAttempts.removeAll()
            self?.reloadChromeUI()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView == chromeWebView else { return }
        Self.logger.fault("chrome navigation failed (provisional): \(error.localizedDescription, privacy: .public)")
        // A replaced load reports as cancelled; anything else leaves the window blank.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        presentChromeRecoveryAlert()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView == chromeWebView else { return }
        Self.logger.fault("chrome navigation failed: \(error.localizedDescription, privacy: .public)")
    }
}
