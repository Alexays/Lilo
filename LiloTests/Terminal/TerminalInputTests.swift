import AppKit
import XCTest
@testable import Lilo

final class TerminalInputTests: XCTestCase {
    func testPrintableKeySendsItsText() {
        let terminal = makeTerminal()

        XCTAssertEqual(encode(key(0x00, "a"), text: "a", terminal), Array("a".utf8))
    }

    func testControlCSendsETX() {
        let terminal = makeTerminal()

        XCTAssertEqual(encode(key(0x08, "\u{3}", ignoring: "c", flags: .control), text: nil, terminal), [0x03])
    }

    func testOptionAsMetaPrefixesEscapeInsteadOfTypingACharacter() {
        let terminal = makeTerminal()
        let optionB = key(0x0B, "\u{222B}", ignoring: "b", flags: .option)

        XCTAssertEqual(encode(optionB, text: "b", optionIsMeta: true, terminal), Array("\u{1b}b".utf8))
        XCTAssertEqual(encode(optionB, text: "\u{222B}", terminal), Array("\u{222B}".utf8), "Option types its character by default")
    }

    func testPromptJumpsStepThroughEarlierCommands() {
        let terminal = makeTerminal()
        let output = String(repeating: "out\r\n", count: 6)
        feed(terminal, "\u{1b}]133;A\u{7}$ one\r\n" + output + "\u{1b}]133;A\u{7}$ two\r\n" + output + "\u{1b}]133;A\u{7}$ ")

        XCTAssertTrue(terminal.scrollToPrompt(older: true))
        XCTAssertEqual(terminal.line(row: 0)?.text, "$ two")
        XCTAssertTrue(terminal.scrollToPrompt(older: true))
        XCTAssertEqual(terminal.line(row: 0)?.text, "$ one")
        XCTAssertFalse(terminal.scrollToPrompt(older: true))
        XCTAssertTrue(terminal.scrollToPrompt(older: false))
        XCTAssertEqual(terminal.line(row: 0)?.text, "$ two")
    }

    func testArrowFollowsApplicationCursorMode() {
        let terminal = makeTerminal()
        let up = key(0x7E, "\u{F700}")

        XCTAssertEqual(encode(up, text: nil, terminal), Array("\u{1b}[A".utf8))
        feed(terminal, "\u{1b}[?1h")
        XCTAssertEqual(encode(up, text: nil, terminal), Array("\u{1b}OA".utf8))
    }

    func testMultilinePasteNeedsConfirmationUnlessBracketed() {
        let terminal = makeTerminal()

        XCTAssertNil(terminal.encodePaste("ls\nrm -rf x\n", allowUnsafe: false))
        feed(terminal, "\u{1b}[?2004h")
        XCTAssertEqual(terminal.encodePaste("ls\n", allowUnsafe: false), Array("\u{1b}[200~ls\n\u{1b}[201~".utf8))
    }

    func testDraggingSelectsText() {
        let terminal = makeTerminal()
        feed(terminal, "hello world")
        let gesture = VTSelectionGesture()
        let geometry = (columns: 20, cellWidth: 10, paddingX: 0, height: 40)

        gesture.handle(.press, cell: (0, 0), position: CGPoint(x: 2, y: 5), rectangle: false, geometry: geometry, terminal: terminal)
        gesture.handle(.drag, cell: (4, 0), position: CGPoint(x: 46, y: 5), rectangle: false, geometry: geometry, terminal: terminal)
        gesture.handle(.release, cell: (4, 0), position: CGPoint(x: 46, y: 5), rectangle: false, geometry: geometry, terminal: terminal)

        XCTAssertEqual(terminal.selectionText, "hello")
    }

    func testFindSelectsTheNewestMatchAndSteps() throws {
        let terminal = makeTerminal()
        feed(terminal, "alpha one\r\nbeta\r\nalpha two")
        let search = try XCTUnwrap(VTSearch(terminal: terminal))
        func scan(_ needle: String) {
            search.setNeedle(needle)
            while true {
                switch search.tick() {
                case .complete: return
                case .feedRequired: search.feed()
                case .running: continue
                }
            }
        }

        scan("ALPHA")
        XCTAssertEqual(search.matchCount, 2)
        search.step(older: true, terminal: terminal)
        XCTAssertEqual(terminal.selectionText, "alpha")
        scan("missing")
        XCTAssertEqual(search.matchCount, 0)
    }

    func testMouseReportsUseSGRWhenRequested() {
        let terminal = makeTerminal()
        XCTAssertFalse(terminal.tracksMouse)
        feed(terminal, "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertTrue(terminal.tracksMouse)

        let bytes = VTInputEncoder().encodeMouse(
            .press, button: .left, position: CGPoint(x: 15, y: 25), modifiers: [],
            geometry: (width: 200, height: 40, cellWidth: 10, cellHeight: 20, paddingX: 0, paddingY: 0), terminal: terminal
        )

        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1b}[<0;2;2M")
    }

    /// A frame drawn for another size (a pane between two layouts) stays pinned, never stretched.
    @MainActor
    func testAFrameOfAnotherSizeIsPinnedTopLeftInAWindow() throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 80, rows: 5, command: ["/bin/cat"])
        let view = try XCTUnwrap(TerminalView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            view.shutdown()
            session.terminate()
            window.close()
        }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.layer?.contentsGravity, .topLeft)
    }

    @MainActor
    func testVoiceOverReadsTheRowsInView() async throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 80, rows: 5, command: ["/bin/sh", "-c", "printf 'hello voiceover'; sleep 2"])
        let view = try XCTUnwrap(TerminalView(session: session))
        defer {
            view.shutdown()
            session.terminate()
        }
        try session.start()

        let read = await pollUntil(timeout: 5) { (view.accessibilityValue() as? String)?.contains("hello voiceover") == true }
        XCTAssertTrue(read)
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityLabel(), "Terminal".localized)
    }

    @MainActor
    func testCommandClickFindsTheURLUnderTheCell() async throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 80, rows: 5, command: ["/bin/sh", "-c", "printf 'see https://example.com/docs now'; sleep 2"])
        let view = try XCTUnwrap(TerminalView(session: session))
        defer {
            view.shutdown()
            session.terminate()
        }
        try session.start()
        await pollUntil(timeout: 5) { session.withLockedTerminal({ $0.line(row: 0)?.text })?.contains("now") == true }

        let link = view.link(at: (8, 0))
        XCTAssertEqual(link?.url, URL(string: "https://example.com/docs"))
        XCTAssertEqual(link?.rows, [0: 4...27], "the hover underline covers the whole URL")
        XCTAssertNil(view.link(at: (1, 0)))
    }

    @MainActor
    func testCommandClickUnderlinesAnIndentedURLWhereItIsDrawn() async throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 80, rows: 5, command: ["/bin/sh", "-c", "printf '   https://example.com/docs'; sleep 2"])
        let view = try XCTUnwrap(TerminalView(session: session))
        defer {
            view.shutdown()
            session.terminate()
        }
        try session.start()
        await pollUntil(timeout: 5) { session.withLockedTerminal({ $0.line(row: 0)?.text })?.contains("docs") == true }

        XCTAssertEqual(view.link(at: (3, 0))?.rows, [0: 3...26])
        XCTAssertNil(view.link(at: (1, 0)))
    }

    @MainActor
    func testCommandClickOnAWrappedRowFindsTheURL() async throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 20, rows: 5, command: ["/bin/sh", "-c", "printf 'go https://example.com/x ok 日本 https://example.org/b'; sleep 2"])
        let view = try XCTUnwrap(TerminalView(session: session))
        defer {
            view.shutdown()
            session.terminate()
        }
        try session.start()
        await pollUntil(timeout: 5) { session.withLockedTerminal({ $0.line(row: 0)?.text })?.contains("example.org/b") == true }

        // Column 12 of row 1 is the "h" of the second URL: the wide characters take two columns each.
        XCTAssertEqual(view.link(at: (12, 1))?.url, URL(string: "https://example.org/b"))
        XCTAssertEqual(view.link(at: (5, 0))?.url, URL(string: "https://example.com/x"))
    }

    @MainActor
    func testCommandClickJoinsAPathThatTheProgramWrappedOverIndentedRows() async throws {
        let file = NSTemporaryDirectory() + "lilo-wrapped-\(UUID().uuidString).txt"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: nil))
        defer { try? FileManager.default.removeItem(atPath: file) }
        // Each row holds two columns of indent and 38 of the path, filling the 40 columns.
        var chunks: [Substring] = []
        var rest = Substring(file)
        while !rest.isEmpty {
            chunks.append(rest.prefix(38))
            rest = rest.dropFirst(38)
        }
        let output = chunks.map { "  " + $0 }.joined(separator: "\n")
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 40, rows: 8, command: ["/bin/sh", "-c", "printf '%s' \"$0\"; sleep 2", output])
        let view = try XCTUnwrap(TerminalView(session: session))
        defer {
            view.shutdown()
            session.terminate()
        }
        try session.start()
        await pollUntil(timeout: 5) { session.withLockedTerminal({ $0.line(row: chunks.count - 1)?.text })?.contains(".txt") == true }

        var rows = Dictionary(uniqueKeysWithValues: chunks.indices.map { ($0, 2...39) })
        rows[chunks.count - 1] = 2...chunks.last!.count + 1
        for row in chunks.indices {
            let link = view.link(at: (5, row))
            XCTAssertEqual(link?.url, URL(fileURLWithPath: file))
            XCTAssertEqual(link?.rows, rows)
        }
    }

    @MainActor
    func testCommandClickFindsAPathThatEndsASentence() async throws {
        let file = NSTemporaryDirectory() + "lilo-sentence-\(UUID().uuidString).pdf"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: nil))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 200, rows: 5, command: ["/bin/sh", "-c", "printf 'saved: %s.' \"$0\"; sleep 2", file])
        let view = try XCTUnwrap(TerminalView(session: session))
        defer {
            view.shutdown()
            session.terminate()
        }
        try session.start()
        await pollUntil(timeout: 5) { session.withLockedTerminal({ $0.line(row: 0)?.text })?.contains(".pdf.") == true }

        let link = view.link(at: (10, 0))
        XCTAssertEqual(link?.url, URL(fileURLWithPath: file))
        XCTAssertEqual(link?.rows, [0: 7...file.count + 6], "the period is left out of the underline")
    }

    @MainActor
    func testCommandClickPrefersTheHyperlinkOfTheCell() async throws {
        let output = "\u{1b}]8;;https://example.com/target\u{1b}\\docs\u{1b}]8;;\u{1b}\\ https://example.org/text"
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 80, rows: 5, command: ["/bin/sh", "-c", "printf '%s' \"$0\"; sleep 2", output])
        let view = try XCTUnwrap(TerminalView(session: session))
        defer {
            view.shutdown()
            session.terminate()
        }
        try session.start()
        await pollUntil(timeout: 5) { session.withLockedTerminal({ $0.line(row: 0)?.text })?.contains("text") == true }

        let link = view.link(at: (1, 0))
        XCTAssertEqual(link?.url, URL(string: "https://example.com/target"))
        XCTAssertEqual(link?.rows, [0: 0...3])
        XCTAssertEqual(view.link(at: (10, 0))?.url, URL(string: "https://example.org/text"))
    }

    /// After a trackpad scroll the grid rests a fraction of a row lower; a drag over a row selects that row.
    @MainActor
    func testDraggingOverARowShiftedByAPixelScrollSelectsThatRow() async throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 40, rows: 5, command: ["/bin/sh", "-c", "printf 'first\\r\\nsecond\\r\\nthird'; sleep 2"])
        let view = try XCTUnwrap(TerminalView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            view.shutdown()
            session.terminate()
            window.close()
        }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(view)
        try session.start()
        await pollUntil(timeout: 5) { session.withLockedTerminal({ $0.line(row: 2)?.text })?.contains("third") == true }
        let font = try XCTUnwrap(view.font)
        let scale = view.fontScale
        let cellHeight = CGFloat(font.cellHeight)
        let offset = (cellHeight * 0.8).rounded()
        view.renderLoop.lockedScrollOffset = Float(offset)

        // Low in the drawn "first" row: without the offset this pixel falls in row 1.
        let pixelY = TerminalView.padding.height * scale + offset + cellHeight * 0.9
        func event(_ type: NSEvent.EventType, column: CGFloat) -> NSEvent {
            let x = (TerminalView.padding.width * scale + CGFloat(font.cellWidth) * column) / scale
            let point = view.convert(NSPoint(x: x, y: view.bounds.height - pixelY / scale), to: nil)
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        view.mouseDown(with: event(.leftMouseDown, column: 0.2))
        view.mouseDragged(with: event(.leftMouseDragged, column: 4.8))
        view.mouseUp(with: event(.leftMouseUp, column: 4.8))

        XCTAssertEqual(session.withLockedTerminal { $0.selectionText }, "first")
    }

    /// The Command-hover underline goes to the link a Command-click there opens, on a grid shifted by a pixel scroll.
    @MainActor
    func testCommandHoverOverARowShiftedByAPixelScrollFindsThatRowsLink() async throws {
        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 40, rows: 5,
            command: ["/bin/sh", "-c", "printf 'https://one.example/a\\r\\nhttps://two.example/b'; sleep 2"]
        )
        let view = try XCTUnwrap(TerminalView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            view.shutdown()
            session.terminate()
            window.close()
        }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(view)
        try session.start()
        let printed = await pollUntil { session.withLockedTerminal({ $0.line(row: 1)?.text })?.contains("two") == true }
        XCTAssertTrue(printed)
        let font = try XCTUnwrap(view.font)
        let scale = view.fontScale
        let cellHeight = CGFloat(font.cellHeight)
        let offset = (cellHeight * 0.8).rounded()
        view.renderLoop.lockedScrollOffset = Float(offset)

        // Low in the drawn first row: without the offset this pixel falls in row 1.
        let pixelY = TerminalView.padding.height * scale + offset + cellHeight * 0.9
        let x = (TerminalView.padding.width * scale + CGFloat(font.cellWidth) * 3.5) / scale
        view.updateHoveredLink(at: view.convert(NSPoint(x: x, y: view.bounds.height - pixelY / scale), to: nil), command: true)

        XCTAssertEqual(view.hoveredLink?.rows.keys.sorted(), [0])
    }

    private func makeTerminal() -> VTTerminal {
        VTTerminal(cols: 20, rows: 4, scrollbackBytes: 100_000)
    }

    private func feed(_ terminal: VTTerminal, _ text: String) {
        Array(text.utf8).withUnsafeBytes { terminal.write($0) }
    }

    private func key(_ code: UInt16, _ characters: String, ignoring: String? = nil, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code
        )!
    }

    private func encode(_ event: NSEvent, text: String?, optionIsMeta: Bool = false, _ terminal: VTTerminal) -> [UInt8] {
        VTInputEncoder().encodeKey(event, released: false, text: text, optionIsMeta: optionIsMeta, terminal: terminal)
    }
}
