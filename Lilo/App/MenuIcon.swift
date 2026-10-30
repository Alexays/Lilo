import AppKit

/// The SF Symbol of each menu action, so an action shows the same icon in every menu.
/// Where WebKit's own menu items show the same action, the symbol is WebKit's.
enum MenuIcon: CaseIterable {
    case newTab, newTerminalTab, newFolder, newSpace, newWindow, newPrivateSpace
    case openInNewTab, duplicate, openInSplit, arrangeSideBySide, arrangeTopAndBottom, separateSplit
    case moveToFolder, removeFromFolder, openFolder, closeFolder, edit, delete
    case lock, unlock, changePassword, removeLock
    case bookmark, unbookmark, pin, unpin, mute, unmute, keepAwake
    case close, closeOthers, restoreClosedTab, stopAgents
    case back, forward, reload, copyLink, pictureInPicture, download
    case open, quickLook, showInFinder, openInTerminal, retry, cancel, removeFromList
    case details, options, copy, paste, selectAll, clearScreen
    // Main menu actions.
    case checkForUpdates, extensions, newLittleWindow, newTerminalBeside, newTerminalBelow, openLocation, openAsTab, savePage
    case share, qrCode, screenshot, captureArea, captureVisible, captureFullPage, print, copyMarkdown, find, findNext
    case findPrevious, useSelectionForFind, spelling, showSpelling, checkSpelling, spellWhileTyping, checkGrammar, autocorrect
    case substitutions, showSubstitutions, smartQuotes, smartDashes, textReplacement, transformations, speech, sidebar, toolbar
    case fullScreen, reloadFromOrigin, stopLoading, zoomIn, zoomOut, actualSize, reader, translate, showChanges
    case recentlyClosed, archivedTabs, recentlyVisited, history, clearBrowsingData, nextSpace, previousSpace, previousTab, nextTab
    case goToTab, moveToSpace, clearUnpinned, webInspector, inspectElement, console, viewSource, sources, profiling
    case processManager, loadExtension, featureFlags, designSystem, chromeDevtools, hitboxOverlay, nextWaitingTerminal
    case terminals, recentDownloads, help, whatsNew, shortcuts, onboarding, diagnostics, perfRecording, reportIssue, addExtension, manageExtensions

    var symbolName: String {
        switch self {
        case .newTab: "plus.square"
        case .newTerminalTab, .openInTerminal: "terminal"
        case .newFolder: "folder.badge.plus"
        case .newSpace: "rectangle.stack.badge.plus"
        case .newWindow: "interface.window.badge.plus"
        case .newPrivateSpace: "hand.raised"
        case .openInNewTab, .duplicate: "plus.square.on.square"
        case .openInSplit, .arrangeSideBySide: "rectangle.split.2x1"
        case .arrangeTopAndBottom: "rectangle.split.1x2"
        case .separateSplit: "rectangle.split.2x1.slash"
        case .moveToFolder: "arrow.forward.folder"
        case .removeFromFolder: "folder.badge.minus"
        case .openFolder: "rectangle.expand.vertical"
        case .closeFolder: "rectangle.compress.vertical"
        case .edit: "pencil"
        case .delete: "trash"
        case .lock: "lock"
        case .unlock: "lock.open"
        case .changePassword: "key"
        case .removeLock: "lock.slash"
        case .bookmark: "bookmark"
        case .unbookmark: "bookmark.slash"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .mute: "speaker.slash"
        case .unmute: "speaker.wave.2"
        case .keepAwake: "cup.and.saucer"
        case .close: "xmark"
        case .closeOthers: "xmark.square"
        case .restoreClosedTab: "arrow.uturn.backward"
        case .stopAgents: "stop.circle"
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .reload, .retry: "arrow.clockwise"
        case .copyLink: "link"
        case .pictureInPicture: "pip.enter"
        case .download: "square.and.arrow.down"
        case .open: "arrow.up.forward.app"
        case .quickLook: "eye"
        case .showInFinder: "folder"
        case .cancel: "xmark.circle"
        case .removeFromList: "minus.circle"
        case .details: "info.circle"
        case .options: "gearshape"
        case .copy: "document.on.document"
        case .paste: "document.on.clipboard"
        case .selectAll: "selection.pin.in.out"
        case .clearScreen: "eraser"
        case .checkForUpdates: "arrow.triangle.2.circlepath"
        case .whatsNew: "sparkles"
        case .extensions: "puzzlepiece.extension"
        case .newLittleWindow: "macwindow"
        case .newTerminalBeside: "rectangle.righthalf.inset.filled"
        case .newTerminalBelow: "rectangle.bottomhalf.inset.filled"
        case .openLocation: "globe"
        case .openAsTab: "arrow.up.right.square"
        case .savePage: "square.and.arrow.down.on.square"
        case .share: "square.and.arrow.up"
        case .qrCode: "qrcode"
        case .screenshot: "camera.viewfinder"
        case .captureArea: "rectangle.dashed"
        case .captureVisible: "rectangle.inset.filled"
        case .captureFullPage: "doc.richtext"
        case .print: "printer"
        case .copyMarkdown: "m.square"
        case .find: "magnifyingglass"
        case .findNext: "arrow.down"
        case .findPrevious: "arrow.up"
        case .useSelectionForFind: "text.viewfinder"
        case .spelling: "textformat.abc.dottedunderline"
        case .showSpelling: "text.magnifyingglass"
        case .checkSpelling: "checkmark.circle"
        case .spellWhileTyping: "character.cursor.ibeam"
        case .checkGrammar: "textformat.abc"
        case .autocorrect: "wand.and.stars"
        case .substitutions: "textformat.alt"
        case .showSubstitutions: "text.redaction"
        case .smartQuotes: "quote.opening"
        case .smartDashes: "minus"
        case .textReplacement: "arrow.left.arrow.right"
        case .transformations: "textformat"
        case .speech: "waveform"
        case .sidebar: "sidebar.left"
        case .toolbar: "menubar.rectangle"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .reloadFromOrigin: "arrow.clockwise.circle"
        case .stopLoading: "xmark"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .actualSize: "1.magnifyingglass"
        case .reader: "doc.plaintext"
        case .translate: "translate"
        case .showChanges: "plusminus"
        case .recentlyClosed: "clock.arrow.circlepath"
        case .archivedTabs: "archivebox"
        case .recentlyVisited: "clock"
        case .history: "list.bullet"
        case .clearBrowsingData: "trash"
        case .nextSpace: "arrow.right.square"
        case .previousSpace: "arrow.left.square"
        case .previousTab: "chevron.left.square"
        case .nextTab: "chevron.right.square"
        case .goToTab: "number"
        case .moveToSpace: "rectangle.stack"
        case .clearUnpinned: "clear"
        case .webInspector: "wrench.and.screwdriver"
        case .inspectElement: "scope"
        case .console: "text.alignleft"
        case .viewSource: "chevron.left.forwardslash.chevron.right"
        case .sources: "doc.text"
        case .profiling: "speedometer"
        case .processManager: "cpu"
        case .loadExtension: "puzzlepiece"
        case .featureFlags: "flag"
        case .designSystem: "paintpalette"
        case .chromeDevtools: "hammer"
        case .hitboxOverlay: "square.dashed"
        case .nextWaitingTerminal: "bell"
        case .terminals: "list.bullet.rectangle"
        case .recentDownloads: "tray.and.arrow.down"
        case .help: "questionmark.circle"
        case .shortcuts: "keyboard"
        case .onboarding: "play.circle"
        case .diagnostics: "stethoscope"
        case .perfRecording: "record.circle"
        case .reportIssue: "exclamationmark.bubble"
        case .addExtension: "plus.circle"
        case .manageExtensions: "slider.horizontal.3"
        }
    }

    // Each made once, on first use: menus are rebuilt on every open, and most symbols are never shown.
    @MainActor private static var images: [MenuIcon: NSImage] = [:]

    @MainActor var image: NSImage? {
        if let image = Self.images[self] { return image }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        Self.images[self] = image
        return image
    }
}

/// A menu bar item whose symbol image is made when its menu first opens, not when the menu bar is built at launch.
final class SymbolMenuItem: NSMenuItem {
    var symbolName: String?
}

/// Delegate of the menu bar's static menus. It has no `menuHasKeyEquivalent`, so shortcuts still reach their items.
final class MenuBarImageLoader: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.showItemImages()
        // Once is enough: AppKit updates a delegated menu before every shortcut lookup.
        menu.delegate = nil
    }
}

extension NSMenu {
    /// Makes the pending images of `SymbolMenuItem`s, and from macOS 27, where AppKit hides menu item images unless
    /// each item asks to show its own, marks them visible. Called on every menu Lilo shows, after its items are in,
    /// so WebKit's and extensions' items show theirs too.
    func showItemImages() {
        for item in items {
            // AppKit gives the standard items their own symbol when the menu bar is set: that one stays.
            if let item = item as? SymbolMenuItem, let symbolName = item.symbolName {
                if item.image == nil { item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) }
                item.symbolName = nil
            }
            if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
            item.submenu?.showItemImages()
        }
    }
}
