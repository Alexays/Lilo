import AppKit
import Sparkle

extension AppDelegate {
    // MARK: - Main Menu

    /// Adds a titled submenu to `menu` and returns it.
    private func submenu(_ title: String, in menu: NSMenu, icon: MenuIcon? = nil) -> NSMenu {
        let item = SymbolMenuItem(title: title, action: nil, keyEquivalent: "")
        item.symbolName = icon?.symbolName
        let submenu = NSMenu(title: title)
        submenu.delegate = menuBarImages
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = submenu("Lilo", in: mainMenu)
        appMenu.add("About Lilo".localized, #selector(showAboutPanel(_:)))
        if let updaterController {
            let item = appMenu.add("Check for Updates…".localized, #selector(SPUStandardUpdaterController.checkForUpdates(_:)), icon: .checkForUpdates)
            item.target = updaterController
        }
        appMenu.addItem(.separator())
        appMenu.add("Settings…".localized, #selector(MainWindowController.openSettings(_:)), icon: .options, shortcut: "app.settings")
        dynamicMenus[.extensions] = submenu("Extensions".localized, in: appMenu, icon: .extensions)
        appMenu.addItem(.separator())
        NSApp.servicesMenu = submenu("Services".localized, in: appMenu)
        // Selected page text and links reach Services through WKWebView's requestor support.
        NSApp.registerServicesMenuSendTypes([.string, .URL], returnTypes: [])
        appMenu.addItem(.separator())
        appMenu.add("Hide Lilo".localized, #selector(NSApplication.hide(_:)), shortcut: "app.hide")
        appMenu.add("Hide Others".localized, #selector(NSApplication.hideOtherApplications(_:)), shortcut: "app.hideOthers")
        appMenu.add("Show All".localized, #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        appMenu.add("Quit Lilo".localized, #selector(NSApplication.terminate(_:)), shortcut: "app.quit")

        let fileMenu = submenu("File".localized, in: mainMenu)
        fileMenu.add("New Tab".localized, #selector(MainWindowController.newTab(_:)), icon: .newTab, shortcut: "tab.new")
        fileMenu.add("New Window".localized, #selector(newWindow(_:)), icon: .newWindow, shortcut: "window.new")
        fileMenu.add("New Little Window".localized, #selector(newLittleWindow(_:)), icon: .newLittleWindow, shortcut: "littleWindow.new")
        fileMenu.add("New Private Space".localized, #selector(MainWindowController.newPrivateSpace(_:)), icon: .newPrivateSpace, shortcut: "space.newPrivate")
        fileMenu.addItem(.separator())
        fileMenu.add("New Terminal Tab".localized, #selector(MainWindowController.newTerminalTab(_:)), icon: .newTerminalTab, shortcut: "terminal.newTab")
        fileMenu.add("New Terminal Beside".localized, #selector(MainWindowController.newTerminalBeside(_:)), icon: .newTerminalBeside, shortcut: "terminal.newBeside")
        fileMenu.add("New Terminal Below".localized, #selector(MainWindowController.newTerminalBelow(_:)), icon: .newTerminalBelow, shortcut: "terminal.newBelow")
        fileMenu.addItem(.separator())
        fileMenu.add("Open Location…".localized, #selector(MainWindowController.openLocation(_:)), icon: .openLocation, shortcut: "location.open")
        fileMenu.add("Open File…".localized, #selector(openDocument(_:)), shortcut: "file.open")
        fileMenu.add("Open as Tab".localized, #selector(MainWindowController.openPageAsTab(_:)), icon: .openAsTab, shortcut: "page.openAsTab")
        fileMenu.addItem(.separator())
        fileMenu.add("Close Tab".localized, #selector(MainWindowController.closeCurrentTab(_:)), icon: .close, shortcut: "tab.close")
        fileMenu.add("Close Other Tabs".localized, #selector(MainWindowController.closeOtherTabs(_:)), icon: .closeOthers, shortcut: "tab.closeOthers").isAlternate = true
        fileMenu.add("Close Window".localized, #selector(NSWindow.performClose(_:)), shortcut: "window.close")
        fileMenu.addItem(.separator())
        fileMenu.add("Save Page As…".localized, #selector(MainWindowController.savePageAs(_:)), icon: .savePage, shortcut: "page.save")
        fileMenu.add("Share…".localized, #selector(MainWindowController.shareCurrentPage(_:)), icon: .share, shortcut: "page.share")
        fileMenu.add("Create QR Code…".localized, #selector(MainWindowController.showQRCode(_:)), icon: .qrCode, shortcut: "page.qrCode")
        let screenshotMenu = submenu("Take Screenshot".localized, in: fileMenu, icon: .screenshot)
        screenshotMenu.add("Selected Area".localized, #selector(MainWindowController.startRegionSelection(_:)), icon: .captureArea, shortcut: "capture.area")
        screenshotMenu.add("Visible Area".localized, #selector(MainWindowController.takeViewportScreenshot(_:)), icon: .captureVisible, shortcut: "capture.visible")
        screenshotMenu.add("Full Page".localized, #selector(MainWindowController.takeFullPageScreenshot(_:)), icon: .captureFullPage, shortcut: "capture.fullPage")
        fileMenu.add("Print…".localized, #selector(MainWindowController.printCurrentPage(_:)), icon: .print, shortcut: "page.print")

        let editMenu = submenu("Edit".localized, in: mainMenu)
        editMenu.add("Undo".localized, Selector(("undo:")), shortcut: "edit.undo")
        editMenu.add("Redo".localized, Selector(("redo:")), shortcut: "edit.redo")
        editMenu.addItem(.separator())
        editMenu.add("Cut".localized, #selector(NSText.cut(_:)), shortcut: "edit.cut")
        editMenu.add("Copy".localized, #selector(NSText.copy(_:)), shortcut: "edit.copy")
        editMenu.add("Copy Page URL".localized, #selector(MainWindowController.copyCurrentURL(_:)), icon: .copyLink, shortcut: "page.copyURL")
        editMenu.add("Copy Page Link as Markdown".localized, #selector(MainWindowController.copyCurrentURLAsMarkdown(_:)), icon: .copyMarkdown, shortcut: "page.copyMarkdown").isAlternate = true
        editMenu.add("Paste".localized, #selector(NSText.paste(_:)), shortcut: "edit.paste")
        editMenu.add("Paste and Match Style".localized, #selector(NSTextView.pasteAsPlainText(_:)), shortcut: "edit.pasteMatchStyle")
        editMenu.add("Delete".localized, #selector(NSText.delete(_:)))
        editMenu.add("Select All".localized, #selector(NSText.selectAll(_:)), shortcut: "edit.selectAll")
        editMenu.addItem(.separator())
        let findMenu = submenu("Find".localized, in: editMenu)
        findMenu.add("Find…".localized, #selector(MainWindowController.showFindBar(_:)), icon: .find, shortcut: "find.show")
        findMenu.add("Find Next".localized, #selector(MainWindowController.findNextMatch(_:)), icon: .findNext, shortcut: "find.next")
        findMenu.add("Find Previous".localized, #selector(MainWindowController.findPreviousMatch(_:)), icon: .findPrevious, shortcut: "find.previous")
        // Spelling & Grammar: WKWebView handles these standard responder-chain actions when a web text
        // field is focused (it spell-checks editable content by default; this surfaces the controls).
        let spellingMenu = submenu("Spelling and Grammar".localized, in: editMenu, icon: .spelling)
        spellingMenu.add("Show Spelling and Grammar".localized, #selector(NSText.showGuessPanel(_:)), icon: .showSpelling, key: ":")
        spellingMenu.add("Check Document Now".localized, #selector(NSText.checkSpelling(_:)), icon: .checkSpelling, shortcut: "spelling.check")
        spellingMenu.addItem(.separator())
        spellingMenu.add("Check Spelling While Typing".localized, #selector(NSTextView.toggleContinuousSpellChecking(_:)), icon: .spellWhileTyping)
        spellingMenu.add("Check Grammar With Spelling".localized, #selector(NSTextView.toggleGrammarChecking(_:)), icon: .checkGrammar)
        spellingMenu.add("Correct Spelling Automatically".localized, #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), icon: .autocorrect)
        // WKWebView answers these responder-chain actions in editable page content.
        let substitutionsMenu = submenu("Substitutions".localized, in: editMenu, icon: .substitutions)
        substitutionsMenu.add("Show Substitutions".localized, #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), icon: .showSubstitutions)
        substitutionsMenu.addItem(.separator())
        substitutionsMenu.add("Smart Quotes".localized, #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), icon: .smartQuotes)
        substitutionsMenu.add("Smart Dashes".localized, #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), icon: .smartDashes)
        substitutionsMenu.add("Text Replacement".localized, #selector(NSTextView.toggleAutomaticTextReplacement(_:)), icon: .textReplacement)
        let transformationsMenu = submenu("Transformations".localized, in: editMenu, icon: .transformations)
        transformationsMenu.add("Make Upper Case".localized, #selector(NSResponder.uppercaseWord(_:)))
        transformationsMenu.add("Make Lower Case".localized, #selector(NSResponder.lowercaseWord(_:)))
        transformationsMenu.add("Capitalize".localized, #selector(NSResponder.capitalizeWord(_:)))
        let speechMenu = submenu("Speech".localized, in: editMenu, icon: .speech)
        speechMenu.add("Start Speaking".localized, #selector(NSTextView.startSpeaking(_:)))
        speechMenu.add("Stop Speaking".localized, #selector(NSTextView.stopSpeaking(_:)))

        let viewMenu = submenu("View".localized, in: mainMenu)
        viewMenu.add("Hide Sidebar".localized, #selector(MainWindowController.toggleSidebarVisibility(_:)), icon: .sidebar, shortcut: "sidebar.toggle")
        viewMenu.add("Hide Toolbar".localized, #selector(MainWindowController.toggleToolbarVisibility(_:)), icon: .toolbar, shortcut: "toolbar.toggle")
        viewMenu.add("Enter Full Screen".localized, #selector(NSWindow.toggleFullScreen(_:)), icon: .fullScreen, shortcut: "window.fullScreen")
        viewMenu.addItem(.separator())
        viewMenu.add("Reload Page".localized, #selector(MainWindowController.reloadCurrentPage(_:)), icon: .reload, shortcut: "page.reload")
        viewMenu.add("Reload Without Cache".localized, #selector(MainWindowController.reloadCurrentPageFromOrigin(_:)), icon: .reloadFromOrigin, shortcut: "page.reloadFromOrigin").isAlternate = true
        viewMenu.add("Stop".localized, #selector(MainWindowController.stopLoadingCurrentPage(_:)), icon: .stopLoading, shortcut: "page.stop")
        viewMenu.addItem(.separator())
        viewMenu.add("Zoom In".localized, #selector(MainWindowController.zoomInCurrentPage(_:)), icon: .zoomIn, shortcut: "zoom.in")
        viewMenu.add("Zoom Out".localized, #selector(MainWindowController.zoomOutCurrentPage(_:)), icon: .zoomOut, shortcut: "zoom.out")
        viewMenu.add("Actual Size".localized, #selector(MainWindowController.resetCurrentPageZoom(_:)), icon: .actualSize, shortcut: "zoom.reset")
        viewMenu.addItem(.separator())
        viewMenu.add("Show Reader".localized, #selector(MainWindowController.toggleReader(_:)), icon: .reader, shortcut: "page.reader")
        viewMenu.add("Translate Page".localized, #selector(MainWindowController.translatePage(_:)), icon: .translate, shortcut: "page.translate")
        viewMenu.add("Picture in Picture".localized, #selector(MainWindowController.togglePictureInPicture(_:)), icon: .pictureInPicture, shortcut: "page.pictureInPicture")
        viewMenu.addItem(.separator())
        viewMenu.add("Show Changes".localized, #selector(MainWindowController.showChanges(_:)), icon: .showChanges, shortcut: "terminal.showChanges")

        let historyMenu = submenu("History".localized, in: mainMenu)
        historyMenu.add("Back".localized, #selector(MainWindowController.goBackInHistory(_:)), icon: .back, shortcut: "history.back")
        historyMenu.add("Forward".localized, #selector(MainWindowController.goForwardInHistory(_:)), icon: .forward, shortcut: "history.forward")
        historyMenu.addItem(.separator())
        historyMenu.add("Reopen Last Closed Tab".localized, #selector(MainWindowController.restoreClosedTab(_:)), icon: .restoreClosedTab, shortcut: "tab.reopenClosed")
        // Dynamic lists live in their own submenus so key-equivalent lookup never builds them.
        dynamicMenus[.recentlyClosed] = submenu("Recently Closed".localized, in: historyMenu, icon: .recentlyClosed)
        historyMenu.add("Archived Tabs…".localized, #selector(MainWindowController.showArchivedTabs(_:)), icon: .archivedTabs, shortcut: "history.archivedTabs")
        historyMenu.addItem(.separator())
        dynamicMenus[.recentlyVisited] = submenu("Recently Visited".localized, in: historyMenu, icon: .recentlyVisited)
        historyMenu.add("Show All History…".localized, #selector(MainWindowController.openHistory(_:)), icon: .history, shortcut: "history.show")
        historyMenu.add("Clear Browsing Data…".localized, #selector(MainWindowController.clearBrowsingData(_:)), icon: .clearBrowsingData, shortcut: "history.clearBrowsingData")

        // Space and tab shortcuts are matched by the window's key monitor: these menus only show them,
        // so the space list can be rebuilt on open.
        let spacesMenu = submenu("Spaces".localized, in: mainMenu)
        spacesMenu.add("Next Space".localized, #selector(MainWindowController.showNextSpace(_:)), icon: .nextSpace, shortcut: "space.next")
        spacesMenu.add("Previous Space".localized, #selector(MainWindowController.showPreviousSpace(_:)), icon: .previousSpace, shortcut: "space.previous")
        spacesMenu.addItem(.separator())
        spacesMenu.addItem(.separator())
        spacesMenu.add("New Space…".localized, #selector(MainWindowController.newSpace(_:)), icon: .newSpace, shortcut: "space.new")
        spacesMenu.add("Edit Space…".localized, #selector(MainWindowController.editCurrentSpace(_:)), icon: .edit, shortcut: "space.edit")
        dynamicMenus[.spaces] = spacesMenu

        let tabMenu = submenu("Tab".localized, in: mainMenu)
        tabMenu.add("Show Previous Tab".localized, #selector(MainWindowController.showPreviousTab(_:)), icon: .previousTab, shortcut: "tab.previous")
        tabMenu.add("Show Next Tab".localized, #selector(MainWindowController.showNextTab(_:)), icon: .nextTab, shortcut: "tab.next")
        let goToTabMenu = submenu("Go to Tab".localized, in: tabMenu, icon: .goToTab)
        for ordinal in 1...9 {
            let title = ordinal == 9 ? "Last Tab".localized : String(format: "Tab %d".localized, ordinal)
            let item = goToTabMenu.add(title, #selector(MainWindowController.selectTabFromMenu(_:)), shortcut: "tab.select\(ordinal)")
            item.tag = ordinal
            item.symbolName = ordinal == 9 ? "arrow.right.to.line" : "\(ordinal).square"
        }
        tabMenu.addItem(.separator())
        tabMenu.add("Duplicate Tab".localized, #selector(MainWindowController.duplicateCurrentTab(_:)), icon: .duplicate, shortcut: "tab.duplicate")
        tabMenu.add("Pin Tab".localized, #selector(MainWindowController.pinCurrentTab(_:)), icon: .pin, shortcut: "tab.pin")
        tabMenu.add("Bookmark This Page".localized, #selector(MainWindowController.bookmarkCurrentTab(_:)), icon: .bookmark, shortcut: "tab.bookmark")
        dynamicMenus[.moveToFolder] = submenu("Move to Folder".localized, in: tabMenu, icon: .moveToFolder)
        dynamicMenus[.moveToSpace] = submenu("Move to Space".localized, in: tabMenu, icon: .moveToSpace)
        tabMenu.add("Move to New Window".localized, #selector(MainWindowController.moveCurrentTabToNewWindow(_:)), icon: .newWindow, shortcut: "tab.moveToNewWindow")
        tabMenu.addItem(.separator())
        tabMenu.add("New Split View".localized, #selector(MainWindowController.newSplitView(_:)), icon: .openInSplit, shortcut: "split.new")
        tabMenu.add("Separate Split View".localized, #selector(MainWindowController.closeSplitView(_:)), icon: .separateSplit, shortcut: "split.close")
        tabMenu.addItem(.separator())
        tabMenu.add("Mute Tab".localized, #selector(MainWindowController.toggleMuteCurrentTab(_:)), icon: .mute, shortcut: "tab.mute")
        tabMenu.add("Keep Awake Until Done".localized, #selector(MainWindowController.keepCurrentTabAwakeUntilDone(_:)), icon: .keepAwake)
        tabMenu.addItem(.separator())
        tabMenu.add("Clear Unpinned Tabs".localized, #selector(MainWindowController.clearUnpinnedTabs(_:)), icon: .clearUnpinned, shortcut: "tab.clearUnpinned")

        let developMenu = submenu("Develop".localized, in: mainMenu)
        mainMenu.items.last?.tag = Self.developMenuTag
        mainMenu.items.last?.isHidden = UserDefaults.lilo.object(forKey: Self.showDevelopMenuKey) as? Bool == false
        developMenu.add("Show Web Inspector".localized, #selector(MainWindowController.showWebInspector(_:)), icon: .webInspector, shortcut: "devtools.inspector")
        developMenu.add("Inspect Element".localized, #selector(MainWindowController.inspectElement(_:)), icon: .inspectElement, shortcut: "devtools.inspectElement")
        developMenu.add("Show Console".localized, #selector(MainWindowController.showWebInspectorConsole(_:)), icon: .console, shortcut: "devtools.console")
        developMenu.add("View Page Source".localized, #selector(MainWindowController.viewPageSource(_:)), icon: .viewSource, shortcut: "page.viewSource")
        developMenu.add("Show Sources".localized, #selector(MainWindowController.showWebInspectorResources(_:)), icon: .sources, shortcut: "devtools.sources")
        developMenu.addItem(.separator())
        developMenu.add("Toggle Page Profiling".localized, #selector(MainWindowController.toggleWebInspectorPageProfiling(_:)), icon: .profiling)
        developMenu.add("Process Manager".localized, #selector(MainWindowController.openProcessManager(_:)), icon: .processManager, shortcut: "app.processManager")
        developMenu.addItem(.separator())
        developMenu.add("Load Unpacked Extension…".localized, #selector(MainWindowController.loadUnpackedExtension(_:)), icon: .loadExtension)
        developMenu.add("Feature Flags (about:config)…".localized, #selector(MainWindowController.openFeatureFlags(_:)), icon: .featureFlags)
        #if DEBUG
        let developerTools = true
        #else
        let developerTools = UserDefaults.lilo.bool(forKey: Self.developerToolsKey)
        #endif
        let separator = NSMenuItem.separator()
        developMenu.addItem(separator)
        let designSystemItem = developMenu.add("Design System".localized, #selector(MainWindowController.openDesignSystem(_:)), icon: .designSystem)
        let chromeDevtoolsItem = developMenu.add("Open Chrome Devtools".localized, #selector(MainWindowController.showChromeWebInspector(_:)), icon: .chromeDevtools)
        let hitboxDebugItem = developMenu.add("Show Hitbox Debug Overlay".localized, #selector(MainWindowController.toggleHitboxDebug(_:)), icon: .hitboxOverlay)
        hitboxDebugItem.state = UserDefaults.lilo.bool(forKey: MainWindowController.hitboxDebugDefaultsKey) ? .on : .off
        for item in [separator, designSystemItem, chromeDevtoolsItem, hitboxDebugItem] {
            item.tag = Self.developerToolsTag
            item.isHidden = !developerTools
        }

        let windowMenu = submenu("Window".localized, in: mainMenu)
        windowMenu.add("Minimize".localized, #selector(NSWindow.miniaturize(_:)), shortcut: "window.minimize")
        windowMenu.add("Zoom".localized, #selector(NSWindow.zoom(_:)), shortcut: "window.zoom")
        windowMenu.addItem(.separator())
        windowMenu.add("Show Next Waiting Terminal".localized, #selector(MainWindowController.showNextWaitingTerminal(_:)), icon: .nextWaitingTerminal, shortcut: "terminal.nextWaiting")
        dynamicMenus[.terminals] = submenu("Terminals".localized, in: windowMenu, icon: .terminals)
        windowMenu.addItem(.separator())
        windowMenu.add("Downloads".localized, #selector(MainWindowController.openDownloads(_:)), icon: .download, shortcut: "downloads.show")
        dynamicMenus[.downloads] = submenu("Recent Downloads".localized, in: windowMenu, icon: .recentDownloads)
        windowMenu.addItem(.separator())
        windowMenu.add("Bring All to Front".localized, #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windowMenu
        dynamicMenus.values.forEach { $0.delegate = self }

        let helpMenu = submenu("Help".localized, in: mainMenu)
        helpMenu.add("Lilo Help".localized, #selector(MainWindowController.openHelp(_:)), icon: .help)
        helpMenu.add("What’s New".localized, #selector(MainWindowController.showWhatsNew(_:)), icon: .whatsNew)
        helpMenu.add("Keyboard Shortcuts".localized, #selector(MainWindowController.openShortcuts(_:)), icon: .shortcuts, shortcut: "help.shortcuts")
        helpMenu.add("Replay Onboarding".localized, #selector(MainWindowController.replayOnboarding(_:)), icon: .onboarding)
        helpMenu.addItem(.separator())
        helpMenu.add("Diagnostics".localized, #selector(MainWindowController.openDiagnostics(_:)), icon: .diagnostics)
        helpMenu.add("Record Performance Session".localized, #selector(MainWindowController.togglePerfRecording(_:)), icon: .perfRecording)
        helpMenu.add("Report an Issue…".localized, #selector(MainWindowController.reportIssue(_:)), icon: .reportIssue)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @IBAction func showAboutPanel(_ sender: Any?) {
        let font = NSFont.systemFont(ofSize: 11)
        let credits = NSMutableAttributedString(string: "Your internet, in bloom.".localized + "\n", attributes: [.font: font])
        credits.append(NSAttributedString(string: "getlilo.app", attributes: [.font: font, .link: URL(string: "https://getlilo.app")!]))
        credits.append(NSAttributedString(string: " · ", attributes: [.font: font]))
        credits.append(NSAttributedString(string: "GitHub", attributes: [.font: font, .link: URL(string: "https://github.com/Alexays/Lilo")!]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: - NSMenuDelegate

    /// The last pages visited in the active window's profile, newest first.
    private func updateRecentHistory(in menu: NSMenu) {
        menu.removeAllItems()
        let entries = (try? mainWindowController?.profileContext?.history.recentEntries(limit: 12)) ?? []
        // Without an action, menu auto-enabling greys the placeholder out.
        if entries.isEmpty { menu.addItem(withTitle: "No History".localized, action: nil, keyEquivalent: "") }
        for entry in entries {
            guard let url = URL(string: entry.url) else { continue }
            let title = entry.title.isEmpty ? (url.host() ?? entry.url) : entry.title
            let item = NSMenuItem(title: title.count > 60 ? String(title.prefix(59)) + "\u{2026}" : title,
                                  action: #selector(MainWindowController.openHistoryItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = entry.url
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.add("Show All History…".localized, #selector(MainWindowController.openHistory(_:)), icon: .history)
    }

    /// No dynamic menu answers a shortcut (the window's key monitor matches those), so key-equivalent
    /// lookup skips populating them.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kind = dynamicMenus.first(where: { $0.value === menu })?.key else { return }
        let controller = NSApp.mainWindow?.windowController as? MainWindowController ?? mainWindowController
        defer {
            menu.showItemImages()
            menu.autoenablesItems = controller?.isShowingWhatsNew != true
            if controller?.isShowingWhatsNew == true { menu.items.forEach { $0.isEnabled = false } }
        }
        switch kind {
        case .extensions: break
        case .recentlyVisited: return updateRecentHistory(in: menu)
        case .recentlyClosed: controller?.populateRecentlyClosedMenu(menu); return
        case .spaces: controller?.populateSpacesMenu(menu); return
        case .moveToFolder: controller?.populateMoveToFolderMenu(menu); return
        case .moveToSpace: controller?.populateMoveToSpaceMenu(menu); return
        case .terminals: controller?.populateTerminalsMenu(menu); return
        case .downloads: controller?.populateDownloadsMenu(menu); return
        }

        menu.removeAllItems()

        guard let controller else {
            menu.add("Add Extension…".localized, #selector(MainWindowController.addExtension(_:)), icon: .addExtension)
            return
        }

        let loadedExtensions = controller.profileContext?.extensions.loadedExtensions ?? []

        for entry in loadedExtensions {
            let action = entry.context.action(for: nil)
            let title = action.flatMap { $0.label.isEmpty ? nil : $0.label } ?? entry.id
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = action?.icon(for: CGSize(width: 16, height: 16))

            let nativeMenuItems = action?.menuItems ?? []
            if !nativeMenuItems.isEmpty {
                let submenu = NSMenu(title: title)
                nativeMenuItems.forEach { submenu.addItem($0) }
                if action?.presentsPopup == true {
                    submenu.addItem(.separator())
                    let openItem = NSMenuItem(title: "Open Popup".localized, action: #selector(MainWindowController.openExtensionFromMenu(_:)), keyEquivalent: "")
                    openItem.image = MenuIcon.open.image
                    openItem.representedObject = entry.id
                    submenu.addItem(openItem)
                }
                item.submenu = submenu
            } else {
                item.action = #selector(MainWindowController.openExtensionFromMenu(_:))
                item.representedObject = entry.id
            }

            menu.addItem(item)
        }

        if !loadedExtensions.isEmpty {
            menu.addItem(.separator())
        }

        menu.add("Add Extension…".localized, #selector(MainWindowController.addExtension(_:)), icon: .addExtension)
        menu.addItem(.separator())
        menu.add("Manage Extensions".localized, #selector(MainWindowController.manageExtensions(_:)), icon: .manageExtensions)
        menu.add("Check for Extension Updates".localized, #selector(checkForExtensionUpdates(_:)), icon: .checkForUpdates).target = self
    }

    /// Opens the extensions settings, where the check's progress and outcome show.
    @objc private func checkForExtensionUpdates(_ sender: Any?) {
        guard let controller = NSApp.mainWindow?.windowController as? MainWindowController,
              let registry = controller.profileContext?.extensions else { return }
        controller.manageExtensions(nil)
        Task { await registry.updater.checkForUpdates() }
    }
}

@MainActor
extension NSMenu {
    /// `addItem(withTitle:...)` with the keys of a `KeyboardShortcuts` action, so menu setup stays one line per item.
    /// The icon's image is made by `showItemImages()` when the menu opens.
    @discardableResult
    func add(_ title: String, _ action: Selector?, icon: MenuIcon? = nil, key: String = "", shortcut: String? = nil) -> SymbolMenuItem {
        let item = SymbolMenuItem(title: title, action: action, keyEquivalent: key)
        item.symbolName = icon?.symbolName
        addItem(item)
        if let shortcut { KeyboardShortcuts.bind(item, to: shortcut) }
        return item
    }
}
