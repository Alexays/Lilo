import AppKit

extension TerminalView {
    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Command shortcuts belong to the menus and Lilo's own key handling.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if !hasMarkedText(), optionSendsMeta(event) {
            // The key itself, unshifted by Option: Option-B reaches the shell as Escape-b.
            let text = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option))
            sendKey(event, released: false, text: text?.isEmpty == false ? text : nil, optionIsMeta: true)
            NSCursor.setHiddenUntilMouseMoves(true)
            return
        }
        let wasComposing = hasMarkedText()
        typedText = []
        // Runs the input method: dead keys, Option characters and IME composition land in
        // insertText or setMarkedText; everything else falls through to doCommand.
        interpretKeyEvents([event])
        let text = typedText?.joined() ?? ""
        typedText = nil
        if hasMarkedText() || (wasComposing && text.isEmpty) { return }
        sendKey(event, released: false, text: text.isEmpty ? nil : text)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    /// Terminal shortcuts that would otherwise reach the menus. Only the focused terminal takes them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        // AppKit turns Control-Return into a context menu request; the running program gets the key instead.
        if flags.contains(.control), !flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            keyDown(with: event)
            return true
        }
        switch (flags, event.keyCode) {
        case ([.command], 126), ([.command], 125):
            // Command-Up and Command-Down step through earlier commands by their prompts.
            let moved = session.withLockedTerminal { terminal in
                let moved = terminal.scrollToPrompt(older: event.keyCode == 126)
                if moved { renderLoop.lockedScrollOffset = 0 }
                return moved
            }
            if moved {
                scrollRemainder = 0
                renderLoop.setNeedsFrame()
            } else {
                NSSound.beep()
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { return super.keyUp(with: event) }
        guard session.reportsKeyReleases.load(ordering: .relaxed) else { return }
        sendKey(event, released: true, text: nil, optionIsMeta: optionSendsMeta(event))
    }

    override func doCommand(by selector: Selector) {
        // Keys like Return, Tab and arrows are encoded from the event itself, not as text commands.
    }

    private func optionSendsMeta(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option) else { return false }
        // Device-dependent bits of the modifier flags tell the left Option key from the right one.
        let left = event.modifierFlags.rawValue & UInt(NX_DEVICELALTKEYMASK) != 0
        let right = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        switch optionAsMeta {
        case .off: return false
        case .left: return left
        case .right: return right
        case .both: return true
        }
    }

    func sendKey(_ event: NSEvent, released: Bool, text: String?, optionIsMeta: Bool = false) {
        let bytes = session.withLockedTerminal { terminal in
            let bytes = input.encodeKey(event, released: released, text: text, optionIsMeta: optionIsMeta, terminal: terminal)
            if !bytes.isEmpty, !released {
                terminal.scrollToBottom()
                renderLoop.lockedScrollOffset = 0
            }
            return bytes
        }
        guard !bytes.isEmpty else { return }
        if !released { scrollRemainder = 0 }
        session.write(bytes)
        renderLoop.setNeedsFrame()
        // Shells without integration report nothing, so a new command line is the moment to look.
        if !released, event.keyCode == 36 || event.keyCode == 76 { session.refreshForegroundProcess() }
    }

    // MARK: - Mouse

    /// Pointer position in pixels from the view's top left, and the viewport cell under it.
    private func location(at windowPoint: NSPoint) -> (pixel: CGPoint, cell: (x: Int, y: Int))? {
        guard let font, grid.cols > 0, grid.rows > 0 else { return nil }
        let point = convert(windowPoint, from: nil)
        // The grid rests shifted by what a trackpad scroll left short of a whole row.
        let pixel = CGPoint(x: point.x * fontScale, y: (bounds.height - point.y) * fontScale - CGFloat(renderLoop.lockedScrollOffset))
        let column = Int(((pixel.x - Self.padding.width * fontScale) / CGFloat(font.cellWidth)).rounded(.down))
        let row = Int(((pixel.y - Self.padding.height * fontScale) / CGFloat(font.cellHeight)).rounded(.down))
        return (pixel, (min(max(column, 0), grid.cols - 1), min(max(row, 0), grid.rows - 1)))
    }

    private var mouseGeometry: (width: Int, height: Int, cellWidth: Int, cellHeight: Int, paddingX: Int, paddingY: Int) {
        (
            Int(bounds.width * fontScale), Int(bounds.height * fontScale), font?.cellWidth ?? 1, font?.cellHeight ?? 1,
            Int(Self.padding.width * fontScale), Int(Self.padding.height * fontScale)
        )
    }

    private var selectionGeometry: (columns: Int, cellWidth: Int, paddingX: Int, height: Int) {
        (grid.cols, font?.cellWidth ?? 1, Int(Self.padding.width * fontScale), Int(bounds.height * fontScale))
    }

    /// Sends a mouse report when the running program tracks the mouse (Shift keeps it local).
    private func reportMouse(_ action: VTInputEncoder.MouseAction, button: VTInputEncoder.MouseButton, event: NSEvent) -> Bool {
        guard session.tracksMouse.load(ordering: .relaxed), let location = location(at: event.locationInWindow),
              !event.modifierFlags.contains(.shift) else { return false }
        let geometry = mouseGeometry
        let bytes = session.withLockedTerminal { terminal -> [UInt8]? in
            guard terminal.tracksMouse else { return nil }
            return input.encodeMouse(action, button: button, position: location.pixel, modifiers: event.modifierFlags, geometry: geometry, terminal: terminal)
        }
        guard let bytes else { return false }
        if !bytes.isEmpty { session.write(bytes) }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let location = location(at: event.locationInWindow) else { return }
        if event.modifierFlags.contains(.command), let target = link(at: location.cell) {
            updateHoveredLink(at: event.locationInWindow, command: false)
            onOpenURL?(target.url)
            return
        }
        reportingMouse = reportMouse(.press, button: .left, event: event)
        guard !reportingMouse else { return }
        // A click on a command's bar in the left padding selects what the command printed.
        if location.pixel.x < Self.padding.width * fontScale,
           session.withLockedTerminal({ $0.selectCommandOutput(atViewportRow: location.cell.y) }) {
            renderLoop.setNeedsFrame()
            return
        }
        let geometry = selectionGeometry
        session.withLockedTerminal { terminal in
            selectionGesture.handle(
                .press, cell: location.cell, position: location.pixel,
                rectangle: event.modifierFlags.contains(.option), geometry: geometry, terminal: terminal
            )
        }
        renderLoop.setNeedsFrame()
    }

    override func mouseDragged(with event: NSEvent) {
        if reportingMouse {
            _ = reportMouse(.motion, button: .left, event: event)
            return
        }
        guard let location = location(at: event.locationInWindow) else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Dragging past the top or bottom edge scrolls the history under the selection.
        let scroll = point.y > bounds.height ? -1 : point.y < 0 ? 1 : 0
        let geometry = selectionGeometry
        session.withLockedTerminal { terminal in
            if scroll != 0 { terminal.scrollViewport(by: scroll) }
            selectionGesture.handle(
                .drag, cell: location.cell, position: location.pixel,
                rectangle: event.modifierFlags.contains(.option), geometry: geometry, terminal: terminal
            )
        }
        renderLoop.setNeedsFrame()
    }

    override func mouseUp(with event: NSEvent) {
        if reportingMouse {
            _ = reportMouse(.release, button: .left, event: event)
            reportingMouse = false
            return
        }
        guard let location = location(at: event.locationInWindow) else { return }
        let geometry = selectionGeometry
        session.withLockedTerminal { terminal in
            selectionGesture.handle(.release, cell: location.cell, position: location.pixel, rectangle: false, geometry: geometry, terminal: terminal)
        }
        renderLoop.setNeedsFrame()
    }

    override func rightMouseDown(with event: NSEvent) {
        if !reportMouse(.press, button: .right, event: event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !reportMouse(.release, button: .right, event: event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        _ = reportMouse(.press, button: .middle, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        _ = reportMouse(.release, button: .middle, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredLink(at: event.locationInWindow, command: event.modifierFlags.contains(.command))
        updateHoveredMark(atRow: location(at: event.locationInWindow).flatMap { $0.pixel.x < Self.padding.width * fontScale ? $0.cell.y : nil })
        _ = reportMouse(.motion, button: .none, event: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        (hoveredLink == nil && hoveredMarkRows == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let font, let location = location(at: event.locationInWindow) else { return }
        let cellHeight = CGFloat(font.cellHeight)
        let geometry = mouseGeometry
        let precise = event.hasPreciseScrollingDeltas
        let delta = precise ? event.scrollingDeltaY * fontScale : event.scrollingDeltaY.rounded(.awayFromZero) * cellHeight
        let bytes = session.withLockedTerminal { terminal -> [UInt8] in
            scrollRemainder += delta
            let lines = Int(scrollRemainder / cellHeight)
            scrollRemainder -= CGFloat(lines) * cellHeight
            // Programs that take the wheel themselves get whole lines, never a pixel offset.
            if terminal.tracksMouse || terminal.isAlternateScreen {
                guard lines != 0 else { return [] }
                if terminal.tracksMouse {
                    let report = input.encodeMouse(
                        .press, button: lines > 0 ? .wheelUp : .wheelDown, position: location.pixel,
                        modifiers: event.modifierFlags, geometry: geometry, terminal: terminal
                    )
                    return Array(repeating: report, count: abs(lines)).flatMap { $0 }
                }
                // Full-screen programs without mouse support (less, man) scroll with the arrow keys.
                let applicationCursor = terminal.mode(1)
                let arrow = lines > 0 ? (applicationCursor ? "\u{1b}OA" : "\u{1b}[A") : (applicationCursor ? "\u{1b}OB" : "\u{1b}[B")
                return Array(repeating: Array(arrow.utf8), count: abs(lines)).flatMap { $0 }
            }
            // History scrolls by whole rows; the rest of a trackpad gesture shifts the grid by pixels.
            if lines != 0 { terminal.scrollViewport(by: -lines) }
            let edges = terminal.scrollEdges
            if (edges.atTop && scrollRemainder > 0) || (edges.atBottom && scrollRemainder < 0) || !precise {
                scrollRemainder = 0
            }
            renderLoop.lockedScrollOffset = Float(scrollRemainder)
            return []
        }
        if !bytes.isEmpty { session.write(bytes) }
        renderLoop.scrolled()
    }

    // MARK: - Links

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The link under the cell, for Command-click, and the columns it covers on each viewport row:
    /// an OSC 8 hyperlink, else a URL or an existing file path read from the text.
    func link(at cell: (x: Int, y: Int)) -> (url: URL, rows: [Int: ClosedRange<Int>])? {
        if let hyperlink = session.withLockedTerminal({ $0.hyperlink(row: cell.y, column: cell.x) }) {
            return URL(string: hyperlink.uri).map { ($0, hyperlink.rows) }
        }
        typealias Glyph = (character: Character, row: Int, column: Int, columns: Int, home: Bool)
        guard let glyphs = session.withLockedTerminal({ terminal -> [Glyph]? in
            let width = terminal.columns
            func glyphs(of row: Int, home: Bool = false) -> [Glyph] {
                guard let line = terminal.line(row: row) else { return [] }
                var column = 0
                return line.text.map { character in
                    // Wide characters (CJK, emoji) take two columns.
                    let scalar = character.unicodeScalars.first!
                    let columns = scalar.properties.isEmojiPresentation ? 2 : max(1, Int(wcwidth(wchar_t(scalar.value))))
                    defer { column += columns }
                    return (character, line.top + column / width, column % width, columns, home)
                }
            }
            // A program wrapping its own output ends a full row with a newline and indents the next
            // one: a line filled to the last column carries on after the next row's indent.
            func reachesEdge(_ line: [Glyph]) -> Bool {
                line.last { !$0.character.isWhitespace }.map { $0.column + $0.columns == width } ?? false
            }
            var line = glyphs(of: cell.y, home: true)
            while reachesEdge(line), let last = line.last?.row, last + 1 < terminal.rows {
                let next = glyphs(of: last + 1).drop { $0.character.isWhitespace }
                guard !next.isEmpty else { break }
                line += next
            }
            while let top = line.first?.row, top > 0 {
                let previous = glyphs(of: top - 1)
                guard reachesEdge(previous) else { break }
                line = previous + line.drop { $0.character.isWhitespace }
            }
            return line
        }), let clicked = glyphs.firstIndex(where: { $0.row == cell.y && ($0.column..<$0.column + $0.columns).contains(cell.x) }),
            !glyphs[clicked].character.isWhitespace else { return nil }
        func rows(_ range: ClosedRange<Int>) -> [Int: ClosedRange<Int>] {
            var rows: [Int: ClosedRange<Int>] = [:]
            for glyph in glyphs[range] {
                let columns = glyph.column...glyph.column + glyph.columns - 1
                rows[glyph.row] = rows[glyph.row].map { $0.lowerBound...columns.upperBound } ?? columns
            }
            return rows
        }
        let characters = glyphs.map(\.character)
        let line = String(characters)
        if let detector = Self.linkDetector {
            for match in detector.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line), let url = match.url else { continue }
                let start = line.distance(from: line.startIndex, to: range.lowerBound)
                let end = start + line[range].count - 1
                if (start...end).contains(clicked) { return (url, rows(start...end)) }
            }
        }
        // A whitespace-delimited token that names a file, with an optional ":line:column" suffix.
        var start = clicked
        var end = clicked
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        while end + 1 < characters.count, !characters[end + 1].isWhitespace { end += 1 }
        // Joining rows can glue the word of the next row to a path: the clicked line alone is the fallback.
        let home = glyphs.firstIndex { $0.home }!...glyphs.lastIndex { $0.home }!
        let token = start...end
        let quotes: Set<Character> = ["'", "\"", "(", ")", "[", "]", ","]
        // A path that ends a sentence carries its punctuation.
        let trailing: Set<Character> = [".", ";", ":", "!", "?"]
        let base = session.status.cwd ?? NSHomeDirectory()
        for candidate in home.contains(start) && home.contains(end) ? [token] : [token, token.clamped(to: home)] {
            var first = candidate.lowerBound
            var last = candidate.upperBound
            while first < last, quotes.contains(characters[first]) { first += 1 }
            while last > first, quotes.contains(characters[last]) || trailing.contains(characters[last]) { last -= 1 }
            var name = String(characters[first...last])
            while let colon = name.lastIndex(of: ":"), name[name.index(after: colon)...].allSatisfy(\.isNumber) {
                name = String(name[..<colon])
            }
            let path = name.hasPrefix("~") ? (name as NSString).expandingTildeInPath
                : name.hasPrefix("/") ? name : (base as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) { return (URL(fileURLWithPath: path), rows(first...last)) }
        }
        return nil
    }

    /// With Command held, the link under the pointer is underlined and its target shown.
    func updateHoveredLink(at windowPoint: NSPoint, command: Bool) {
        var found: (url: URL, rows: [Int: ClosedRange<Int>])?
        // The cell a Command-click there opens, the grid's pixel scroll offset included.
        let cell = command && bounds.contains(convert(windowPoint, from: nil)) ? location(at: windowPoint)?.cell : nil
        // Looking up a link reads the line and runs a detector: once per cell, not per pixel moved.
        if let cell, hoveredLink?.rows[cell.y]?.contains(cell.x) == true { return }
        if let cell, let probed = probedLinkCell, probed == cell { return }
        probedLinkCell = cell
        if let cell { found = link(at: cell) }
        let hovered = found.map { TerminalLink(rows: $0.rows) }
        guard hovered != hoveredLink else { return }
        hoveredLink = hovered
        renderLoop.setLink(hovered)
        (hovered == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
        if let url = found?.url {
            linkLabel.stringValue = url.isFileURL ? (url.path as NSString).abbreviatingWithTildeInPath : url.absoluteString
            linkLabel.sizeToFit()
            linkLabel.frame.size.width = min(linkLabel.frame.width + 12, bounds.width - 16)
            linkLabel.frame.origin = NSPoint(x: 8, y: 8)
            linkLabel.isHidden = false
        } else {
            linkLabel.isHidden = true
        }
    }

    /// The command bar beside `row` in the left padding widens and takes a pointing hand, telling
    /// that a click selects its output.
    func updateHoveredMark(atRow row: Int?) {
        if let row, hoveredMarkRows?.contains(row) == true { return }
        let rows = row.flatMap { row in
            session.withLockedTerminal { $0.visibleCommandMarks() }.first { $0.rows.contains(row) }?.rows
        }
        guard rows != hoveredMarkRows else { return }
        hoveredMarkRows = rows
        renderLoop.setHoveredMarkRow(rows?.lowerBound)
        toolTip = rows == nil ? nil : "Click to select this command's output".localized
        (rows == nil && hoveredLink == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        updateHoveredLink(at: window.mouseLocationOutsideOfEventStream, command: event.modifierFlags.contains(.command))
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredLink(at: event.locationInWindow, command: false)
        updateHoveredMark(atRow: nil)
    }

    // MARK: - Find

    /// Searches output and history off the main thread, selects the newest match and returns how
    /// many there are. A newer query abandons this one, which then returns nil.
    func find(_ query: String) async -> Int? {
        let generation = searchState.generation.add(1, ordering: .acquiringAndReleasing).newValue
        let session = session
        let state = searchState
        let count: Int? = await withCheckedContinuation { continuation in
            Self.searchQueue.async {
                continuation.resume(returning: state.run(query, generation: generation, session: session))
            }
        }
        renderLoop.setNeedsFrame()
        return count
    }

    func findAgain(older: Bool) {
        // The step moves the selection without any output: the frame is asked for once it is done.
        Self.searchQueue.async { [session, searchState, renderLoop] in
            searchState.step(older: older, session: session)
            renderLoop.setNeedsFrame()
        }
    }

    func endFind() {
        _ = searchState.generation.add(1, ordering: .acquiringAndReleasing)
        Self.searchQueue.async { [session, searchState, renderLoop] in
            searchState.end(session: session)
            renderLoop.setNeedsFrame()
        }
    }

    // MARK: - Pasteboard

    @objc func copy(_ sender: Any?) {
        guard let text = session.withLockedTerminal({ $0.selectionText }), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = Self.text(from: .general) else { return }
        insert(text)
    }

    /// Files and folders as shell-escaped paths, links as their URL, anything else as text.
    private static func text(from pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if !urls.isEmpty {
            return urls.map { url in
                guard url.isFileURL else { return url.absoluteString }
                return String(url.path.flatMap { character -> [Character] in
                    character.isLetter || character.isNumber || "/._-+~@%:,=".contains(character) ? [character] : ["\\", character]
                })
            }.joined(separator: " ") + " "
        }
        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return nil }
        return string
    }

    /// Types text in as a paste: bracketed when the program asked for it, after a confirmation when
    /// a line break would run a command by itself.
    func insert(_ text: String) {
        if let bytes = session.withLockedTerminal({ $0.encodePaste(text, allowUnsafe: false) }) {
            writePaste(bytes)
            return
        }
        // Without bracketed paste a newline runs whatever precedes it the moment it lands.
        let alert = NSAlert()
        alert.messageText = "Paste text with line breaks?".localized
        alert.informativeText = "Each line will run as a command as soon as it is pasted.".localized
        alert.addButton(withTitle: "Paste".localized)
        alert.addButton(withTitle: "Cancel".localized)
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let bytes = session.withLockedTerminal({ $0.encodePaste(text, allowUnsafe: true) }) else { return }
            writePaste(bytes)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: confirm) } else { confirm(alert.runModal()) }
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = Self.text(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        insert(text)
        return true
    }

    private func writePaste(_ bytes: [UInt8]) {
        session.withLockedTerminal { terminal in
            terminal.scrollToBottom()
            renderLoop.lockedScrollOffset = 0
        }
        scrollRemainder = 0
        session.write(bytes)
        renderLoop.setNeedsFrame()
    }

    override func selectAll(_ sender: Any?) {
        session.withLockedTerminal { $0.selectAll() }
        renderLoop.setNeedsFrame()
    }

    @objc func clearScreen(_ sender: Any?) {
        // Form feed: the shell redraws its prompt at the top, as Ctrl-L does.
        session.write([0x0C])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy".localized, action: #selector(copy(_:)), keyEquivalent: "").image = MenuIcon.copy.image
        menu.addItem(withTitle: "Paste".localized, action: #selector(paste(_:)), keyEquivalent: "").image = MenuIcon.paste.image
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All".localized, action: #selector(selectAll(_:)), keyEquivalent: "").image = MenuIcon.selectAll.image
        menu.addItem(withTitle: "Clear Screen".localized, action: #selector(clearScreen(_:)), keyEquivalent: "").image = MenuIcon.clearScreen.image
        menu.showItemImages()
        return menu
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            session.withLockedTerminal { $0.selectionText?.isEmpty == false }
        case #selector(paste(_:)):
            Self.text(from: .general) != nil
        default:
            true
        }
    }
}

// MARK: - Input method

extension TerminalView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        unmarkText()
        if typedText != nil {
            typedText?.append(text)
        } else if !text.isEmpty {
            // Text inserted outside a key press (emoji picker, dictation) goes straight to the shell.
            session.write(Array(text.utf8))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        updatePreedit()
    }

    func unmarkText() {
        markedText = NSAttributedString()
        updatePreedit()
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// The cursor cell in screen coordinates, so candidate windows open next to the text.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect(), to: nil))
    }

    private func cursorRect() -> NSRect {
        guard let font, fontScale > 0 else { return .zero }
        let cursor = session.withLockedTerminal { $0.cursorPosition }
        let width = CGFloat(font.cellWidth) / fontScale
        let height = CGFloat(font.cellHeight) / fontScale
        let x = Self.padding.width + CGFloat(cursor.x) * width
        let top = Self.padding.height + CGFloat(cursor.y) * height
        return NSRect(x: x, y: bounds.height - top - height, width: width, height: height)
    }

    /// Text still being composed (dead keys, Japanese and Chinese input) shown at the cursor.
    private func updatePreedit() {
        guard hasMarkedText(), let font else {
            preeditLabel.isHidden = true
            return
        }
        let face = NSFont(descriptor: (font.faces[0] as NSFont).fontDescriptor, size: (font.faces[0] as NSFont).pointSize / fontScale)
        preeditLabel.attributedStringValue = NSAttributedString(string: markedText.string, attributes: [
            .font: face as Any,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.textColor
        ])
        preeditLabel.drawsBackground = true
        preeditLabel.backgroundColor = .textBackgroundColor
        preeditLabel.sizeToFit()
        let rect = cursorRect()
        preeditLabel.frame.origin = NSPoint(x: rect.minX, y: rect.minY)
        preeditLabel.isHidden = false
    }
}
