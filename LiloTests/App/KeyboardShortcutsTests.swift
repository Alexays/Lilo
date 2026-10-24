import AppKit
import XCTest
@testable import Lilo

@MainActor
final class KeyboardShortcutsTests: XCTestCase {
    private var database: TemporaryProfileDatabase?

    override func tearDown() {
        KeyboardShortcuts.applyPreset("lilo", store: nil)
        database?.tearDown()
        database = nil
        super.tearDown()
    }

    private func keyDown(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, in controller: MainWindowController) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: controller.window!.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    func testOverrideMovesTheMenuItemAndTheWindowShortcut() {
        let controller = MainWindowController()
        let item = NSMenuItem(title: "Close Tab", action: #selector(MainWindowController.closeCurrentTab(_:)), keyEquivalent: "")
        KeyboardShortcuts.bind(item, to: "tab.close")
        XCTAssertEqual(item.keyEquivalent, "w")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertTrue(controller.handleKeyboardShortcut(keyDown("w", .command, keyCode: 13, in: controller)))

        KeyboardShortcuts.set("tab.close", to: ["⌥⌘k"], store: nil)

        XCTAssertEqual(item.keyEquivalent, "k")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .command])
        XCTAssertTrue(controller.handleKeyboardShortcut(keyDown("k", [.option, .command], keyCode: 40, in: controller)))
        XCTAssertFalse(controller.handleKeyboardShortcut(keyDown("w", .command, keyCode: 13, in: controller)))
    }

    func testShiftedLetterAndArrowKeysMatchTheirCombos() {
        let controller = MainWindowController()
        XCTAssertEqual(KeyboardShortcuts.combo(for: keyDown("T", [.shift, .command], keyCode: 17, in: controller)), "⇧⌘t")
        XCTAssertEqual(KeyboardShortcuts.combo(for: keyDown("\u{F703}", [.option, .command, .numericPad, .function], keyCode: 124, in: controller)), "⌥⌘right")
        XCTAssertEqual(KeyboardShortcuts.combo(for: keyDown("\u{F708}", [], keyCode: 96, in: controller)), "f5")
        XCTAssertNil(KeyboardShortcuts.combo(for: keyDown("T", .shift, keyCode: 17, in: controller)))
        XCTAssertEqual(KeyboardShortcuts.display("⌥⌘right"), "⌥⌘→")
        XCTAssertEqual(KeyboardShortcuts.display("⇧⌘t"), "⇧⌘T")
    }

    func testRecordingAKeyHeldElsewhereAsksBeforeTakingIt() {
        let controller = MainWindowController()
        controller.recordingShortcutId = "tab.pin"

        XCTAssertTrue(controller.handleMonitoredKeyboardEvent(keyDown("x", [], keyCode: 7, in: controller)))
        XCTAssertEqual(controller.recordingShortcutId, "tab.pin", "a key without ⌘, ⌃ or ⌥ never binds")

        XCTAssertTrue(controller.handleMonitoredKeyboardEvent(keyDown("d", .command, keyCode: 2, in: controller)))
        XCTAssertNil(controller.recordingShortcutId)
        XCTAssertEqual(KeyboardShortcuts.bindings("tab.pin"), [], "the conflict waits for Settings to confirm")
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌘d")?.id, "terminal.newBeside")

        // Settings' Replace: the other action is left unbound.
        KeyboardShortcuts.set("tab.pin", to: ["⌘d"], store: nil)
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌘d")?.id, "tab.pin")
        XCTAssertEqual(KeyboardShortcuts.bindings("terminal.newBeside"), [])

        // Resetting a row takes its defaults back.
        KeyboardShortcuts.set("terminal.newBeside", to: nil, store: nil)
        XCTAssertEqual(KeyboardShortcuts.bindings("terminal.newBeside"), ["⌘d"])
        XCTAssertEqual(KeyboardShortcuts.bindings("tab.pin"), [])
    }

    func testRecordingEscapeCancelsAndDeleteUnbinds() {
        let controller = MainWindowController()
        controller.recordingShortcutId = "page.reload"
        XCTAssertTrue(controller.handleMonitoredKeyboardEvent(keyDown("\u{1b}", [], keyCode: 53, in: controller)))
        XCTAssertNil(controller.recordingShortcutId)
        XCTAssertEqual(KeyboardShortcuts.bindings("page.reload"), ["⌘r"])

        controller.recordingShortcutId = "page.reload"
        XCTAssertTrue(controller.handleMonitoredKeyboardEvent(keyDown("\u{7f}", [], keyCode: 51, in: controller)))
        XCTAssertEqual(KeyboardShortcuts.bindings("page.reload"), [])
        XCTAssertNil(KeyboardShortcuts.owner(of: "⌘r"))
    }

    func testArcPresetReplacesTheOverrides() {
        KeyboardShortcuts.set("page.reload", to: ["⌥⌘e"], store: nil)
        KeyboardShortcuts.applyPreset("arc", store: nil)

        XCTAssertEqual(KeyboardShortcuts.bindings("page.reload"), ["⌘r"])
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌘s")?.id, "sidebar.toggle")
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌘d")?.id, "tab.pin")
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌥⌘down")?.id, "tab.next")
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌃tab")?.id, "tab.recentNext", "Arc's Control-Tab walks tabs by last use")
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌃⇧-")?.id, "split.close", "Arc's Control-Shift-Minus removes the split")

        KeyboardShortcuts.applyPreset("lilo", store: nil)
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌘s")?.id, "page.save")
        XCTAssertTrue(KeyboardShortcuts.overrides.isEmpty)
    }

    func testCommandOOpensAsTabAndOpenFileIsUnbound() {
        for preset in ["lilo", "arc"] {
            KeyboardShortcuts.applyPreset(preset, store: nil)
            XCTAssertEqual(KeyboardShortcuts.owner(of: "⌘o")?.id, "page.openAsTab", preset)
            XCTAssertEqual(KeyboardShortcuts.bindings("file.open"), [], preset)
        }
        XCTAssertEqual(KeyboardShortcuts.actionsById["file.open"]?.defaults, [])
    }

    func testASavedOpenFileBindingStillLoads() throws {
        let database = try TemporaryProfileDatabase(schema: .global)
        self.database = database
        let store = SettingsStore(dbPool: database.pool)
        store.set(KeyboardShortcuts.settingsKey, value: #"{"file.open":["⇧⌘o"]}"#)
        try database.pool.write { _ in } // waits for the queued write

        KeyboardShortcuts.load(from: SettingsStore(dbPool: database.pool))

        XCTAssertEqual(KeyboardShortcuts.bindings("file.open"), ["⇧⌘o"])
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌘o")?.id, "page.openAsTab")
    }

    func testControlTabOrderMovesBothCombosAndKeepsTheOtherKeys() {
        XCTAssertEqual(KeyboardShortcuts.bridgePayload["controlTabOrder"] as? String, "recent")

        KeyboardShortcuts.setControlTabOrder(recent: false, store: nil)

        XCTAssertEqual(KeyboardShortcuts.bindings("tab.next"), ["⇧⌘]", "⌥⌘right", "⌃tab"])
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌃⇧tab")?.id, "tab.previous")
        XCTAssertEqual(KeyboardShortcuts.bindings("tab.recentNext"), [])
        XCTAssertEqual(KeyboardShortcuts.bridgePayload["controlTabOrder"] as? String, "sidebar")

        KeyboardShortcuts.setControlTabOrder(recent: true, store: nil)

        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌃tab")?.id, "tab.recentNext")
        XCTAssertEqual(KeyboardShortcuts.owner(of: "⌃⇧tab")?.id, "tab.recentPrevious")
        XCTAssertTrue(KeyboardShortcuts.overrides.isEmpty, "back on the defaults")
    }

    func testEveryPresetIsConflictFree() {
        for (name, preset) in KeyboardShortcuts.presets {
            XCTAssertTrue(Set(preset.keys).isSubset(of: Set(KeyboardShortcuts.actionsById.keys)), name)
            KeyboardShortcuts.applyPreset(name, store: nil)
            var owners: [String: String] = [:]
            for action in KeyboardShortcuts.actions {
                for combo in KeyboardShortcuts.bindings(action.id) {
                    XCTAssertNil(owners[combo], "\(name): \(combo) is bound to \(owners[combo] ?? "") and \(action.id)")
                    owners[combo] = action.id
                }
            }
        }
    }

    func testTheLittleWindowHotKeyFollowsItsBinding() {
        // Keys no other app is likely to hold, so registering them succeeds.
        KeyboardShortcuts.set("littleWindow.new", to: ["⌃⌥⇧⌘y"], store: nil)
        let hotKey = LittleWindowHotKey {}
        XCTAssertNil(hotKey.combo, "off until enabled")

        hotKey.setEnabled(true)
        XCTAssertEqual(hotKey.combo, "⌃⌥⇧⌘y")

        KeyboardShortcuts.set("littleWindow.new", to: ["⌃⌥⇧⌘f19"], store: nil)
        XCTAssertEqual(hotKey.combo, "⌃⌥⇧⌘f19")

        KeyboardShortcuts.set("littleWindow.new", to: [], store: nil)
        XCTAssertNil(hotKey.combo, "an unbound action has no global hot key")

        KeyboardShortcuts.set("littleWindow.new", to: ["⌃⌥⇧⌘y"], store: nil)
        hotKey.setEnabled(false)
        XCTAssertNil(hotKey.combo)
    }

    func testOverridesRoundTripThroughTheSettingsStore() throws {
        let database = try TemporaryProfileDatabase(schema: .global)
        self.database = database
        let store = SettingsStore(dbPool: database.pool)
        KeyboardShortcuts.applyPreset("arc", store: store)
        KeyboardShortcuts.set("tab.close", to: [], store: store)
        try database.pool.write { _ in } // waits for the queued writes
        KeyboardShortcuts.applyPreset("lilo", store: nil)

        KeyboardShortcuts.load(from: SettingsStore(dbPool: database.pool))

        XCTAssertEqual(KeyboardShortcuts.bindings("tab.close"), [])
        XCTAssertEqual(KeyboardShortcuts.bindings("sidebar.toggle"), ["⌘s"])
        XCTAssertEqual(KeyboardShortcuts.overrides.count, KeyboardShortcuts.presets["arc"]!.count + 1)
    }

    func testTheChromeGetsTheKeysThatWorkWithItsInitialState() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId, isPrivate: false)
        let window = makeTestWindow(context, showing: space.id)
        KeyboardShortcuts.applyPreset("arc", store: nil)
        let events = BridgeEventRecorder(window.bridgeRouter)

        window.sendInitialState()

        // The bridge ships at the end of the main-queue turn, which an async test reaches only by suspending.
        await pollUntil { events.events.contains { $0.name == "shortcutKeys" } }
        let keys = try XCTUnwrap(events.data("shortcutKeys").last?["keys"] as? [String: String])
        XCTAssertEqual(keys["sidebar.toggle"], "⌘S")
        XCTAssertEqual(keys["page.save"], "⇧⌘S")
        XCTAssertNil(keys["terminal.newBeside"], "an unbound action shows no keys")
    }
}
