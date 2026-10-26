import AppKit
import WebKit

/// Real mouse and keyboard events for an agent tab, delivered straight to its web view so they never
/// go through the window's event routing or take the user's keyboard focus.
/// Points are in the web view's own coordinates, origin top left: the space of an agent screenshot.
@MainActor
enum AgentInput {
    enum MouseButton { case left, right, middle }

    /// WebKit focuses a clicked field asynchronously; a key sent sooner can be lost.
    private static let focusSettleDelay: Duration = .milliseconds(200)
    private static var lastClickAt = ContinuousClock.now - .seconds(1)
    /// The content world agent scripts run in, out of reach of the page's own scripts.
    static let world = WKContentWorld.world(name: "lilo-agent")

    static func click(
        _ webView: WKWebView, at point: CGPoint, button: MouseButton = .left,
        clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) async {
        AgentCursorView.show(in: webView, at: point, pressed: true)
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        case .middle: (.otherMouseDown, .otherMouseUp)
        }
        // A double or triple click is the whole sequence, each press counting one more.
        await press(webView, at: point, down: mouse(down, webView, point, modifiers: modifiers), up: mouse(up, webView, point, modifiers: modifiers))
        for count in stride(from: 2, through: clickCount, by: 1) {
            send(mouse(down, webView, point, clickCount: count, modifiers: modifiers), to: webView)
            send(mouse(up, webView, point, clickCount: count, modifiers: modifiers), to: webView)
        }
        lastClickAt = .now
    }

    static func move(_ webView: WKWebView, to point: CGPoint) {
        AgentCursorView.show(in: webView, at: point, animated: true)
        send(mouse(.mouseMoved, webView, point), to: webView)
    }

    static func drag(_ webView: WKWebView, from start: CGPoint, to end: CGPoint) async {
        AgentCursorView.show(in: webView, at: start, pressed: true)
        await press(webView, at: start, down: mouse(.leftMouseDown, webView, start), up: nil)
        let steps = 10
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            send(mouse(.leftMouseDragged, webView, point), to: webView)
            AgentCursorView.show(in: webView, at: point)
            try? await Task.sleep(for: .milliseconds(16))
        }
        send(mouse(.leftMouseUp, webView, end), to: webView)
        await afterPendingEvents(webView, "_doAfterProcessingAllPendingMouseEvents:")
    }

    /// Positive `deltaY` scrolls the page down, positive `deltaX` scrolls it right.
    static func scroll(_ webView: WKWebView, at point: CGPoint, deltaX: CGFloat, deltaY: CGFloat, showsCursor: Bool = true) {
        if showsCursor { AgentCursorView.show(in: webView, at: point, animated: true) }
        guard let window = webView.window,
              let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(-deltaY.rounded()), wheel2: Int32(-deltaX.rounded()), wheel3: 0
              ) else { return }
        let screenPoint = window.convertPoint(toScreen: windowPoint(webView, point))
        // CGEvent locations are global, origin top left of the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: screenPoint.x, y: mainHeight - screenPoint.y)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        webView.scrollWheel(with: event)
    }

    /// WKWebView's text substitution switches, which AppKit's Edit menu toggles but Swift does not see.
    static let substitutionKeys = ["automaticQuoteSubstitutionEnabled", "automaticDashSubstitutionEnabled", "automaticTextReplacementEnabled"]

    /// Types `text` one character at a time, as key presses the page sees.
    static func type(_ webView: WKWebView, text: String) async {
        await settleFocus()
        guard !text.isEmpty else { return }
        await withoutSubstitutions(webView) {
            for character in text {
                let string = String(character)
                pressKey(webView, characters: string, ignoringModifiers: string.lowercased(),
                         keyCode: keyCodes[string.lowercased()] ?? 0, modifiers: character.isUppercase ? [.shift] : [])
                // A rich editor (X's composer) opens the new paragraph, then puts the caret in it at its next
                // render: keys sent before that land in the old one, out of order.
                if character.isNewline {
                    await afterPendingEvents(webView, "_doAfterProcessingAllPendingKeyEvents:")
                    await afterRender(webView)
                }
            }
            // WebKit queues the keys: the call returns once the page, or the frame holding the focus, has handled them all.
            await afterPendingEvents(webView, "_doAfterProcessingAllPendingKeyEvents:")
        }
    }

    /// Inserts `text` at the caret in one go, as the text system does for a dictation or an emoji: no key
    /// presses, and the clipboard is left alone.
    static func insertText(_ webView: WKWebView, text: String) async {
        await settleFocus()
        guard !text.isEmpty else { return }
        await withoutSubstitutions(webView) {
            webView.insertText(text)
            // Sent to the page's process after the insertion: answered once the page has it.
            _ = try? await webView.callAsyncJavaScript("return 0", arguments: [:], in: nil, contentWorld: world)
        }
    }

    /// The user's smart quotes, dashes and text replacements would rewrite what the agent types ("--cask" into an
    /// em dash): off while it types. They are global to every web view, so they come back right after.
    private static func withoutSubstitutions(_ webView: WKWebView, _ body: () async -> Void) async {
        let saved = substitutionKeys.map { webView.value(forKey: $0) as? Bool ?? false }
        for key in substitutionKeys { webView.setValue(false, forKey: key) }
        await body()
        for (key, value) in zip(substitutionKeys, saved) { webView.setValue(value, forKey: key) }
    }

    /// Returns once the page has rendered a frame and run what that render scheduled, or after 100 ms in a page
    /// that is not painted.
    private static func afterRender(_ webView: WKWebView) async {
        let script = "await new Promise(done => { setTimeout(done, 100); requestAnimationFrame(() => setTimeout(done, 0)) })"
        _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: world)
    }

    /// One mouse event, sent as is with no agent cursor: chrome.debugger's `Input.dispatchMouseEvent`.
    static func mouseEvent(
        _ type: NSEvent.EventType, _ webView: WKWebView, at point: CGPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags
    ) {
        send(mouse(type, webView, point, clickCount: clickCount, modifiers: modifiers), to: webView)
    }

    /// One key going down or up, for chrome.debugger's `Input.dispatchKeyEvent`: `key` is a DOM key name
    /// like "Enter" or "a", `text` what the press types, if anything.
    static func keyEvent(
        _ webView: WKWebView, down: Bool, key: String, text: String, keyCode: UInt16?, modifiers: NSEvent.ModifierFlags
    ) {
        let named = namedKeys[key.lowercased()]
        let characters = text.isEmpty ? named?.characters ?? (key.count == 1 ? key : "") : text
        pressKey(webView, characters: characters, ignoringModifiers: characters.lowercased(),
                 keyCode: keyCode ?? named?.keyCode ?? keyCodes[key.lowercased()] ?? 0, modifiers: modifiers, types: [down ? .keyDown : .keyUp])
    }

    /// Presses chords like `"cmd+a"`, `"Return"` or `"Backspace Backspace"`: space separated, modifiers joined by `+`.
    static func key(_ webView: WKWebView, chord: String) async {
        await settleFocus()
        for token in chord.split(separator: " ") {
            guard let press = parseChord(String(token)) else { continue }
            let menuCommand = press.modifiers.subtracting(.shift) == .command
                ? menuCommands[press.modifiers.contains(.shift) ? "shift+" + press.ignoringModifiers : press.ignoringModifiers] : nil
            guard let menuCommand else {
                pressKey(webView, characters: press.characters, ignoringModifiers: press.ignoringModifiers,
                         keyCode: press.keyCode, modifiers: press.modifiers)
                continue
            }
            let unhandled = await withCheckedContinuation { (seen: CheckedContinuation<Bool, Never>) in
                webView.callAsyncJavaScript(
                    keyListener, arguments: ["key": press.ignoringModifiers, "shift": press.modifiers.contains(.shift)], in: nil, in: world
                ) { result in
                    seen.resume(returning: (try? result.get()) as? Bool ?? true)
                }
                pressKey(webView, characters: press.characters, ignoringModifiers: press.ignoringModifiers,
                         keyCode: press.keyCode, modifiers: press.modifiers)
            }
            if unhandled, webView.responds(to: menuCommand) { webView.perform(menuCommand, with: nil) }
        }
    }

    /// Shortcuts AppKit runs from the menu bar, which never sees a key sent straight to an agent tab.
    private static let menuCommands: [String: Selector] = [
        "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)), "x": #selector(NSText.cut(_:)),
        "v": #selector(NSText.paste(_:)), "z": Selector(("undo:")), "shift+z": Selector(("redo:"))
    ]

    /// True unless the page took this press's keydown for itself, as a page shortcut does over the menu's.
    /// Decided on the press's own keyup, however late WebKit's key queue delivers it.
    private static let keyListener = """
        // A key landing in a frame is not heard here: the menu command runs.
        if (['IFRAME', 'FRAME', 'EMBED', 'OBJECT'].includes(document.activeElement?.tagName)) return true
        return await new Promise(resolve => {
            let down
            // Keys sent before this press may still be on their way.
            const ours = event => event.metaKey && !event.ctrlKey && !event.altKey && event.shiftKey === shift && event.key.toLowerCase() === key
            const finish = () => {
                removeEventListener('keydown', noteDown, true)
                removeEventListener('keyup', noteUp, true)
                resolve(down ? !down.defaultPrevented : false)
            }
            // Counted from the keydown the page has, so a late key never runs out the clock: only a swallowed keyup does.
            const noteDown = event => { if (ours(event)) { down = event; setTimeout(finish, 2000) } }
            // The keyup comes once every keydown listener ran; with no keydown heard, the page stopped it first.
            const noteUp = event => { if (ours(event)) finish() }
            addEventListener('keydown', noteDown, true)
            addEventListener('keyup', noteUp, true)
        })
        """

    private struct KeyPress {
        let characters: String
        let ignoringModifiers: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
    }

    private static func parseChord(_ token: String) -> KeyPress? {
        var parts = token.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" ends with an empty part: the key itself is "+".
        if parts.count > 1, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("+") }
        guard let keyName = parts.popLast(), !keyName.isEmpty, let modifiers = modifierFlags(parts) else { return nil }
        if let named = namedKeys[keyName.lowercased()] {
            return KeyPress(characters: named.characters, ignoringModifiers: named.characters, keyCode: named.keyCode, modifiers: modifiers)
        }
        guard keyName.count == 1 else { return nil }
        let base = keyName.lowercased()
        let characters = modifiers.contains(.shift) && !modifiers.contains(.command) ? keyName.uppercased() : base
        return KeyPress(characters: characters, ignoringModifiers: base, keyCode: keyCodes[base] ?? 0, modifiers: modifiers)
    }

    /// Sends `down` then `up` until the page has seen the press: WebKit drops pointer events that come
    /// before it is ready for them, right after a load. Pointer events count too, so a page that swallows mouse
    /// events still confirms; a frame's own document cannot be heard from here, so a press on one goes once.
    private static let pressListener = """
        const target = document.elementFromPoint(x, y)
        if (target && ['IFRAME', 'FRAME', 'EMBED', 'OBJECT'].includes(target.tagName)) return
        const press = { down: false, types: ['mousedown', 'pointerdown'] }
        press.note = event => {
            // Before layout a press lands on the document, not on what is drawn there: that is no press.
            const hit = document.elementFromPoint(x, y)
            if (hit && (hit === event.target || hit.contains(event.target) || event.target.contains?.(hit))) press.down = true
        }
        for (const type of press.types) addEventListener(type, press.note, true)
        globalThis.liloPress = press
        """

    /// Whether the armed press went down, and the listener gone. No listener (a frame) means it went once.
    private static let pressHeard = """
        const press = globalThis.liloPress
        delete globalThis.liloPress
        if (!press) return true
        for (const type of press.types) removeEventListener(type, press.note, true)
        return press.down
        """

    private static func press(_ webView: WKWebView, at point: CGPoint, down: NSEvent?, up: NSEvent?) async {
        let zoom = webView.pageZoom
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            // The listener is armed by a call that goes out before the press: WebKit keeps that order.
            webView.callAsyncJavaScript(pressListener, arguments: ["x": point.x / zoom, "y": point.y / zoom], in: nil, in: world) { _ in }
            send(down, to: webView)
            send(up, to: webView)
            // A slow page or a busy app holds the press in WebKit's mouse queue for any time: it is judged
            // only once the page handled it, never on a clock that races its delivery.
            await afterPendingEvents(webView, "_doAfterProcessingAllPendingMouseEvents:")
            let pressed = await withCheckedContinuation { (seen: CheckedContinuation<Bool, Never>) in
                webView.callAsyncJavaScript(pressHeard, arguments: [:], in: nil, in: world) { result in
                    // No script to confirm with (a document going away, a page scripts cannot run in): it went once.
                    seen.resume(returning: (try? result.get()) as? Bool ?? true)
                }
            }
            if pressed { return }
        }
    }

    /// Returns once the page has handled every event of the queue `selectorName` drains (mouse or key) sent so far.
    private static func afterPendingEvents(_ webView: WKWebView, _ selectorName: String) async {
        let selector = NSSelectorFromString(selectorName)
        guard webView.responds(to: selector) else {
            // Without WebKit's word, an event not handled by then counts as dropped.
            try? await Task.sleep(for: .milliseconds(300))
            return
        }
        await withCheckedContinuation { (handled: CheckedContinuation<Void, Never>) in
            let done: @convention(block) () -> Void = { handled.resume() }
            webView.perform(selector, with: done)
        }
    }

    /// `["cmd", "shift"]` as flags; nil for a name that is no modifier.
    static func modifierFlags<S: Sequence>(_ names: S) -> NSEvent.ModifierFlags? where S.Element: StringProtocol {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command", "meta", "super", "win", "windows": flags.insert(.command)
            case "ctrl", "control": flags.insert(.control)
            case "alt", "option", "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "fn": flags.insert(.function)
            default: return nil
            }
        }
        return flags
    }

    private static func settleFocus() async {
        let remaining = lastClickAt + focusSettleDelay - .now
        if remaining > .zero { try? await Task.sleep(for: remaining) }
    }

    private static func pressKey(
        _ webView: WKWebView, characters: String, ignoringModifiers: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        types: [NSEvent.EventType] = [.keyDown, .keyUp]
    ) {
        for type in types {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: webView.window?.windowNumber ?? 0, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode
            ) else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    private static func windowPoint(_ webView: WKWebView, _ point: CGPoint) -> CGPoint {
        let local = CGPoint(x: point.x, y: webView.isFlipped ? point.y : webView.bounds.height - point.y)
        return webView.window == nil ? local : webView.convert(local, to: nil)
    }

    private static func mouse(
        _ type: NSEvent.EventType, _ webView: WKWebView, _ point: CGPoint,
        clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: windowPoint(webView, point), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: webView.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: type == .mouseMoved || type == .leftMouseDragged ? 0 : clickCount,
            pressure: type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp ? 0 : 1
        )
    }

    private static func send(_ event: NSEvent?, to webView: WKWebView) {
        guard let event else { return }
        // WebKit reads an event's `buttons` from `NSEvent.pressedMouseButtons`, the hardware state: unless the
        // button reads as held there, a sent press or drag reaches the page with no button down.
        let held = switch event.type {
        case .leftMouseDown, .leftMouseDragged: heldButtons[0]
        case .rightMouseDown: heldButtons[1]
        case .otherMouseDown: heldButtons[2]
        default: nil as IMP?
        }
        let method = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons))
        let original = held.flatMap { held in method.map { method_setImplementation($0, held) } }
        defer { if let method, let original { method_setImplementation(method, original) } }
        switch event.type {
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .rightMouseDown: webView.rightMouseDown(with: event)
        case .rightMouseUp: webView.rightMouseUp(with: event)
        case .otherMouseDown: webView.otherMouseDown(with: event)
        case .otherMouseUp: webView.otherMouseUp(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        case .mouseMoved:
            // WebKit hit tests a move with no button only in the key window, never an agent tab's: as a drag with
            // no button held, the page sees the same plain move. WKWebView has no mouseMoved: of its own anyway.
            NSEvent.mouseEvent(
                with: .leftMouseDragged, location: event.locationInWindow, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ).map(webView.mouseDragged)
        default: break
        }
    }

    /// `NSEvent.pressedMouseButtons` answering the left, right or middle button held.
    private static let heldButtons = [1, 2, 4].map { mask in
        imp_implementationWithBlock({ (_: AnyObject) in mask } as @convention(block) (AnyObject) -> Int)
    }

    private static let namedKeys: [String: (characters: String, keyCode: UInt16)] = {
        func function(_ key: Int) -> String { String(UnicodeScalar(UInt16(key)).map(Character.init) ?? " ") }
        var keys: [String: (String, UInt16)] = [
            "return": ("\r", 36), "enter": ("\r", 36), "tab": ("\t", 48), "space": (" ", 49),
            "escape": ("\u{1b}", 53), "esc": ("\u{1b}", 53), "backspace": ("\u{7f}", 51),
            "delete": (function(NSDeleteFunctionKey), 117),
            "arrowleft": (function(NSLeftArrowFunctionKey), 123), "left": (function(NSLeftArrowFunctionKey), 123),
            "arrowright": (function(NSRightArrowFunctionKey), 124), "right": (function(NSRightArrowFunctionKey), 124),
            "arrowdown": (function(NSDownArrowFunctionKey), 125), "down": (function(NSDownArrowFunctionKey), 125),
            "arrowup": (function(NSUpArrowFunctionKey), 126), "up": (function(NSUpArrowFunctionKey), 126),
            "home": (function(NSHomeFunctionKey), 115), "end": (function(NSEndFunctionKey), 119),
            "pageup": (function(NSPageUpFunctionKey), 116), "pagedown": (function(NSPageDownFunctionKey), 121)
        ]
        let fKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in fKeyCodes.enumerated() { keys["f\(index + 1)"] = (function(NSF1FunctionKey + index), code) }
        return keys
    }()

    /// ANSI virtual key codes, for the `code` a page reads from a key event.
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49
    ]
}
