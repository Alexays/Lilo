import AppKit
import Carbon.HIToolbox

/// Every app shortcut: defaults, user overrides and System Settings' App Shortcuts. Menus and the key monitor both read it, so they agree.
/// A combo is spelled as macOS shows it: modifiers in ⌃⌥⇧⌘ order, then an unshifted lowercase key ("⇧⌘]", not "⌘}") or a name ("left", "f5").
@MainActor
enum KeyboardShortcuts {
    struct Action {
        let id: String
        let title: String
        /// The menu it sits in, which Settings groups it under.
        let category: String
        let defaults: [String]

        init(_ id: String, _ title: String, _ category: String, _ defaults: [String] = []) {
            self.id = id
            self.title = title.localized
            self.category = category.localized
            self.defaults = defaults
        }
    }

    static let settingsKey = "keyboardShortcuts"
    /// Posted on the main thread whenever a binding may have changed.
    static let didChange = Notification.Name("KeyboardShortcutsDidChange")

    static let actions: [Action] = [
        Action("app.settings", "Settings…", "Lilo", ["⌘,"]),
        Action("app.hide", "Hide Lilo", "Lilo", ["⌘h"]),
        Action("app.hideOthers", "Hide Others", "Lilo", ["⌥⌘h"]),
        Action("app.quit", "Quit Lilo", "Lilo", ["⌘q"]),
        Action("tab.new", "New Tab", "File", ["⌘t"]),
        Action("window.new", "New Window", "File", ["⌘n"]),
        Action("littleWindow.new", "New Little Window", "File", ["⌥⌘n"]),
        Action("space.newPrivate", "New Private Space", "File", ["⇧⌘n"]),
        Action("terminal.newTab", "New Terminal Tab", "File", ["⌃`"]),
        Action("terminal.newBeside", "New Terminal Beside", "File", ["⌘d"]),
        Action("terminal.newBelow", "New Terminal Below", "File", ["⇧⌘d"]),
        Action("location.open", "Open Location…", "File", ["⌘l"]),
        Action("file.open", "Open File…", "File"),
        Action("page.openAsTab", "Open as Tab", "File", ["⌘o"]),
        Action("tab.close", "Close Tab", "File", ["⌘w"]),
        Action("tab.closeOthers", "Close Other Tabs", "File", ["⌥⌘w"]),
        Action("window.close", "Close Window", "File", ["⇧⌘w"]),
        Action("page.save", "Save Page As…", "File", ["⌘s"]),
        Action("page.share", "Share…", "File"),
        Action("page.qrCode", "Create QR Code…", "File"),
        Action("capture.area", "Capture Selected Area", "File", ["⇧⌘2"]),
        Action("capture.visible", "Capture Visible Area", "File"),
        Action("capture.fullPage", "Capture Full Page", "File"),
        Action("page.print", "Print…", "File", ["⌘p"]),
        Action("edit.undo", "Undo", "Edit", ["⌘z"]),
        Action("edit.redo", "Redo", "Edit", ["⇧⌘z"]),
        Action("edit.cut", "Cut", "Edit", ["⌘x"]),
        Action("edit.copy", "Copy", "Edit", ["⌘c"]),
        Action("page.copyURL", "Copy Page URL", "Edit", ["⇧⌘c"]),
        Action("page.copyMarkdown", "Copy Page Link as Markdown", "Edit", ["⌥⇧⌘c"]),
        Action("edit.paste", "Paste", "Edit", ["⌘v"]),
        Action("edit.pasteMatchStyle", "Paste and Match Style", "Edit", ["⌥⇧⌘v", "⇧⌘v"]),
        Action("edit.selectAll", "Select All", "Edit", ["⌘a"]),
        Action("find.show", "Find…", "Edit", ["⌘f"]),
        Action("find.next", "Find Next", "Edit", ["⌘g"]),
        Action("find.previous", "Find Previous", "Edit", ["⇧⌘g"]),
        Action("find.useSelection", "Use Selection for Find", "Edit", ["⌘e"]),
        Action("spelling.check", "Check Document Now", "Edit", ["⌘;"]),
        Action("sidebar.toggle", "Toggle Sidebar", "View", ["⇧⌘s"]),
        Action("toolbar.toggle", "Toggle Toolbar", "View", ["⌥⌘t"]),
        // No default keys: ⌃⌘ with the arrows already switches Spaces.
        Action("tabs.positionLeft", "Move Tabs to the Left", "View"),
        Action("tabs.positionRight", "Move Tabs to the Right", "View"),
        Action("tabs.positionTop", "Move Tabs to the Top", "View"),
        Action("tabs.positionBottom", "Move Tabs to the Bottom", "View"),
        Action("window.fullScreen", "Enter Full Screen", "View", ["⌃⌘f"]),
        Action("page.reload", "Reload Page", "View", ["⌘r"]),
        Action("page.reloadFromOrigin", "Reload Without Cache", "View", ["⇧⌘r"]),
        Action("page.stop", "Stop", "View", ["⌘."]),
        // "⌘+" is the plus key of layouts like German; US layouts type plus with Shift.
        Action("zoom.in", "Zoom In", "View", ["⌘+", "⌘=", "⇧⌘="]),
        Action("zoom.out", "Zoom Out", "View", ["⌘-"]),
        Action("zoom.reset", "Actual Size", "View", ["⌘0"]),
        Action("page.reader", "Show Reader", "View"),
        Action("page.translate", "Translate Page", "View"),
        Action("page.pictureInPicture", "Picture in Picture", "View"),
        Action("terminal.showChanges", "Show Changes", "View", ["⌃⌘g"]),
        Action("history.back", "Back", "History", ["⌘["]),
        Action("history.forward", "Forward", "History", ["⌘]"]),
        Action("tab.reopenClosed", "Reopen Last Closed Tab", "History", ["⇧⌘t"]),
        Action("history.archivedTabs", "Archived Tabs…", "History"),
        Action("history.show", "Show All History…", "History", ["⌘y"]),
        Action("history.clearBrowsingData", "Clear Browsing Data…", "History", ["⇧⌘delete"]),
        Action("space.next", "Next Space", "Spaces", ["⌃⌘right"]),
        Action("space.previous", "Previous Space", "Spaces", ["⌃⌘left"])
    ] + (1...9).map { Action("space.select\($0)", String(format: "Space %d".localized, $0), "Spaces", ["⌃\($0)"]) } + [
        Action("space.new", "New Space…", "Spaces"),
        Action("space.edit", "Edit Space…", "Spaces"),
        Action("tab.previous", "Show Previous Tab", "Tab", ["⇧⌘[", "⌥⌘left"]),
        Action("tab.next", "Show Next Tab", "Tab", ["⇧⌘]", "⌥⌘right"]),
        // After tab.next and tab.previous, so a combo the user gave those keeps sidebar order.
        Action("tab.recentNext", "Switch to Recent Tab", "Tab", ["⌃tab"]),
        Action("tab.recentPrevious", "Switch to Recent Tab Backwards", "Tab", ["⌃⇧tab"])
    ] + (1...9).map { Action("tab.select\($0)", $0 == 9 ? "Last Tab" : String(format: "Tab %d".localized, $0), "Tab", ["⌘\($0)"]) } + [
        Action("tab.duplicate", "Duplicate Tab", "Tab"),
        Action("tab.pin", "Pin Tab", "Tab"),
        Action("tab.bookmark", "Bookmark This Page", "Tab"),
        Action("tab.moveToNewWindow", "Move to New Window", "Tab"),
        Action("split.new", "New Split View", "Tab"),
        Action("split.close", "Separate Split View", "Tab"),
        Action("tab.mute", "Mute Tab", "Tab", ["⇧⌘m"]),
        Action("tab.clearUnpinned", "Clear Unpinned Tabs", "Tab", ["⇧⌘k"]),
        Action("devtools.inspector", "Show Web Inspector", "Develop", ["⌥⌘i"]),
        Action("devtools.inspectElement", "Inspect Element", "Develop", ["⌥⌘c"]),
        Action("devtools.console", "Show Console", "Develop", ["⌥⌘j"]),
        Action("page.viewSource", "View Page Source", "Develop", ["⌥⌘u"]),
        Action("devtools.sources", "Show Sources", "Develop"),
        Action("app.processManager", "Process Manager", "Develop"),
        Action("window.minimize", "Minimize", "Window", ["⌘m"]),
        Action("window.zoom", "Zoom", "Window"),
        Action("terminal.nextWaiting", "Show Next Waiting Terminal", "Window", ["⌃⌘j"]),
        Action("downloads.show", "Downloads", "Window", ["⌥⌘l"]),
        Action("help.shortcuts", "Keyboard Shortcuts", "Help", ["⌘/"])
    ]

    /// Overrides by preset, each conflict-free over the defaults it keeps.
    static let presets: [String: [String: [String]]] = [
        "lilo": [:],
        // Arc's macOS defaults, where Lilo has the action.
        "arc": [
            "sidebar.toggle": ["⌘s"],
            "page.save": ["⇧⌘s"],
            "tab.pin": ["⌘d"],
            "terminal.newBeside": [],
            "tab.previous": ["⌥⌘up", "⇧⌘["],
            "tab.next": ["⌥⌘down", "⇧⌘]"],
            "space.previous": ["⌥⌘left", "⌃⌘left"],
            "space.next": ["⌥⌘right", "⌃⌘right"],
            "split.new": ["⌃⇧="],
            "split.close": ["⌃⇧-"],
            "downloads.show": ["⇧⌘j"]
        ]
    ]

    static let actionsById = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })

    /// Bindings the user changed from the defaults; an empty list leaves the action unbound.
    private(set) static var overrides: [String: [String]] = [:]
    private static var systemOverrides: [String: String] = [:]
    private static var menuItems: [String: NSMenuItem] = [:]
    private static var actionByCombo = lookup()

    static func bindings(_ id: String) -> [String] {
        if let system = systemOverrides[id] { return [system] }
        return overrides[id] ?? actionsById[id]?.defaults ?? []
    }

    /// The action `combo` triggers now, if any.
    static func owner(of combo: String) -> Action? { actionByCombo[combo].flatMap { actionsById[$0] } }

    /// The action a key press triggers, if any.
    static func action(for event: NSEvent) -> String? { combo(for: event).flatMap { actionByCombo[$0] } }

    /// Binds `id` to `combos` (nil restores its defaults), taking each combo from the action holding it.
    static func set(_ id: String, to combos: [String]?, store: SettingsStore?) {
        var next = overrides
        for combo in combos ?? actionsById[id]?.defaults ?? [] {
            if let owner = actionByCombo[combo], owner != id { next[owner] = (next[owner] ?? bindings(owner)).filter { $0 != combo } }
        }
        next[id] = combos
        apply(next, store: store)
    }

    static func applyPreset(_ name: String, store: SettingsStore?) { apply(presets[name] ?? [:], store: store) }

    static func load(from store: SettingsStore) {
        let stored = store.get(settingsKey).flatMap { try? JSONDecoder().decode([String: [String]].self, from: Data($0.utf8)) }
        apply(stored ?? [:], store: nil)
    }

    /// Replaces the overrides, shows them in the menus and saves them to `store`.
    private static func apply(_ next: [String: [String]], store: SettingsStore?) {
        overrides = next.filter { id, combos in actionsById[id].map { $0.defaults != combos } ?? false }
        actionByCombo = lookup()
        for (id, item) in menuItems where systemOverrides[id] == nil { show(id, on: item) }
        NotificationCenter.default.post(name: didChange, object: nil)
        guard let store else { return }
        if overrides.isEmpty {
            store.remove(settingsKey)
        } else if let data = try? JSONEncoder().encode(overrides), let json = String(bytes: data, encoding: .utf8) {
            store.set(settingsKey, value: json)
        }
    }

    private static func lookup() -> [String: String] {
        var table: [String: String] = [:]
        for action in actions {
            for combo in bindings(action.id) where table[combo] == nil { table[combo] = action.id }
        }
        return table
    }

    // MARK: - Menus

    /// Gives `item` the keys of `id` now and whenever they change.
    static func bind(_ item: NSMenuItem, to id: String) {
        menuItems[id] = item
        guard !item.userKeyEquivalent.isEmpty else { return show(id, on: item) }
        // AppKit already moved the item onto the keys System Settings gives it: those win.
        var key = item.keyEquivalent
        var modifiers = item.keyEquivalentModifierMask.intersection(modifierFlags)
        if let name = keysByName.first(where: { $0.value.equivalent == key })?.key {
            key = name
        } else if key != key.lowercased() {
            modifiers.insert(.shift)
            key = key.lowercased()
        }
        systemOverrides[id] = combo(key, modifiers)
        actionByCombo = lookup()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Sets `item`'s key equivalent to the first binding of `id`.
    static func show(_ id: String, on item: NSMenuItem) {
        guard let combo = bindings(id).first else {
            item.keyEquivalent = ""
            return
        }
        let (key, modifiers) = parse(combo)
        item.keyEquivalent = keysByName[key]?.equivalent ?? key
        item.keyEquivalentModifierMask = modifiers
    }

    // MARK: - Keys

    private static let modifierFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    private static let modifierGlyphs: [(flag: NSEvent.ModifierFlags, glyph: Character)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
    ]
    private static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// Keys without a printable character, by key code: their name, glyph and menu key equivalent.
    private static let namedKeys: [UInt16: (name: String, glyph: String, equivalent: String)] = {
        func char(_ code: Int) -> String { String(UnicodeScalar(code)!) }
        var keys: [UInt16: (name: String, glyph: String, equivalent: String)] = [
            123: ("left", "←", char(NSLeftArrowFunctionKey)), 124: ("right", "→", char(NSRightArrowFunctionKey)),
            125: ("down", "↓", char(NSDownArrowFunctionKey)), 126: ("up", "↑", char(NSUpArrowFunctionKey)),
            48: ("tab", "⇥", "\t"), 36: ("return", "↩", "\r"), 76: ("return", "↩", "\r"), 53: ("escape", "⎋", "\u{1b}"),
            51: ("delete", "⌫", "\u{8}"), 117: ("forwarddelete", "⌦", char(NSDeleteFunctionKey)), 49: ("space", "Space", " "),
            115: ("home", "↖", char(NSHomeFunctionKey)), 119: ("end", "↘", char(NSEndFunctionKey)),
            116: ("pageup", "⇞", char(NSPageUpFunctionKey)), 121: ("pagedown", "⇟", char(NSPageDownFunctionKey))
        ]
        for (index, code) in functionKeyCodes.enumerated() {
            keys[code] = ("f\(index + 1)", "F\(index + 1)", char(NSF1FunctionKey + index))
        }
        return keys
    }()
    private static let keysByName = Dictionary(namedKeys.values.map { ($0.name, (glyph: $0.glyph, equivalent: $0.equivalent)) }) { first, _ in first }

    /// The combo `event` types, or nil without ⌘, ⌃ or ⌥ (a function key alone counts), as typing keys never bind.
    static func combo(for event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(modifierFlags)
        guard functionKeyCodes.contains(event.keyCode) || !modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        let key: String
        if let named = namedKeys[event.keyCode] {
            key = named.name
        } else if event.keyCode == 50 || event.keyCode == 10 {
            // The key left of 1 (ANSI 50, ISO 10) is a dead backtick on layouts like French, with no character.
            key = "`"
        } else {
            guard let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else { return nil }
            // Shift spells a symbol key's other character ("}" for "]"): name the key by its own.
            if modifiers.contains(.shift), typed.uppercased() == typed,
               let base = event.characters(byApplyingModifiers: []), !base.isEmpty {
                key = base.lowercased()
            } else {
                key = typed
            }
        }
        return combo(key, modifiers)
    }

    /// The key code typing `combo`'s key on the current keyboard layout, and its modifiers; nil when no key types it.
    static func keyStroke(_ combo: String) -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)? {
        let (key, modifiers) = parse(combo)
        if let code = namedKeys.first(where: { $0.value.name == key })?.key { return (code, modifiers) }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { bytes -> (UInt16, NSEvent.ModifierFlags)? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var chars = [UniChar](repeating: 0, count: 4)
            // Ascending, so a main-row key wins over the keypad key typing the same character.
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
                if status == noErr, String(utf16CodeUnits: chars, count: length).lowercased() == key { return (code, modifiers) }
            }
            return nil
        }
    }

    private static func combo(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
        var combo = ""
        for (flag, glyph) in modifierGlyphs where modifiers.contains(flag) { combo.append(glyph) }
        return combo + key
    }

    private static func parse(_ combo: String) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        var modifiers: NSEvent.ModifierFlags = []
        var key = Substring(combo)
        while let first = key.first, let flag = modifierGlyphs.first(where: { $0.glyph == first })?.flag {
            modifiers.insert(flag)
            key = key.dropFirst()
        }
        return (String(key), modifiers)
    }

    /// The combo as macOS menus show it: "⇧⌘T", "⌥⌘←".
    static func display(_ combo: String) -> String {
        let key = parse(combo).key
        return String(combo.dropLast(key.count)) + (keysByName[key]?.glyph ?? key.uppercased())
    }

    /// Each bound action's first keys as menus show them, for the hints the chrome shows.
    static var displayedKeys: [String: String] {
        var keys: [String: String] = [:]
        for action in actions {
            if let combo = bindings(action.id).first { keys[action.id] = display(combo) }
        }
        return keys
    }

    /// Gives ⌃⇥ and ⌃⇧⇥ to the recent tabs switcher, or back to the sidebar's next and previous tab.
    static func setControlTabOrder(recent: Bool, store: SettingsStore?) {
        for (combo, recentId, sidebarId) in [("⌃tab", "tab.recentNext", "tab.next"), ("⌃⇧tab", "tab.recentPrevious", "tab.previous")] {
            let id = recent ? recentId : sidebarId
            if !bindings(id).contains(combo) { set(id, to: bindings(id) + [combo], store: store) }
        }
    }

    /// Settings > Shortcuts: every action by menu, with its keys as shown and whether the user changed them,
    /// and the order ⌃⇥ walks tabs in.
    static var bridgePayload: [String: Any] {
        var groups: [(title: String, items: [[String: Any]])] = []
        for action in actions {
            let item: [String: Any] = [
                "id": action.id, "title": action.title,
                "keys": bindings(action.id).map(display), "custom": overrides[action.id] != nil
            ]
            if groups.last?.title == action.category { groups[groups.count - 1].items.append(item) } else { groups.append((action.category, [item])) }
        }
        return [
            "groups": groups.map { ["title": $0.title, "items": $0.items] },
            "controlTabOrder": actionByCombo["⌃tab"] == "tab.recentNext" ? "recent" : "sidebar"
        ]
    }
}
