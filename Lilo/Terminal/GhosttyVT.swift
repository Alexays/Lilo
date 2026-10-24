import AppKit
import GhosttyVt
import OSLog

/// The only type that touches the libghostty-vt C API. Not thread-safe: the owner serializes every
/// call, and callbacks run synchronously inside `write(_:)`.
final class VTTerminal: @unchecked Sendable {
    enum PromptEvent: Equatable {
        case promptStart
        /// The command line, when the shell sends it.
        case outputStart(command: String?)
        case commandEnd(exitCode: Int32?)
    }

    /// A command in the history: where its prompt and its output start, and how it ended. The
    /// tracked references follow the rows as output scrolls and the screen reflows.
    final class CommandBlock {
        let prompt: GhosttyTrackedGridRef
        var output: GhosttyTrackedGridRef?
        var exitCode: Int32?

        init(prompt: GhosttyTrackedGridRef) {
            self.prompt = prompt
        }

        deinit {
            ghostty_tracked_grid_ref_free(prompt)
            if let output { ghostty_tracked_grid_ref_free(output) }
        }
    }

    /// Oldest first. Each tracked reference costs a little on every terminal mutation, so only
    /// the most recent commands keep one.
    private(set) var commandBlocks: [CommandBlock] = []
    private static let commandBlockLimit = 500

    let handle: GhosttyTerminal
    var onWritePty: ((UnsafeRawBufferPointer) -> Void)?
    var onTitleChanged: (() -> Void)?
    var onPwdChanged: (() -> Void)?
    var onPrompt: ((PromptEvent) -> Void)?
    /// A program asked for a desktop notification (OSC 9 or OSC 777): title (may be empty), body.
    var onDesktopNotification: ((String, String) -> Void)?
    /// The bell character (BEL) arrived.
    var onBell: (() -> Void)?

    convenience init(cols: UInt16, rows: UInt16, scrollbackBytes: Int) {
        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, cols, rows) == GHOSTTY_SUCCESS, let terminal else {
            fatalError("libghostty-vt could not allocate a terminal")
        }
        self.init(handle: terminal, scrollbackBytes: scrollbackBytes)
    }

    /// A terminal as `snapshot()` saved it, history compressed while it loads. Nil when the data
    /// is not a snapshot this version of libghostty-vt can read.
    convenience init?(snapshot: Data, scrollbackBytes: Int) {
        let terminal = snapshot.withUnsafeBytes { bytes -> GhosttyTerminal? in
            var decoder: GhosttySnapshotDecoder?
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  ghostty_snapshot_decoder_new_buf(nil, &decoder, base, bytes.count) == GHOSTTY_SUCCESS, let decoder else { return nil }
            defer { ghostty_snapshot_decoder_free(decoder) }
            var compress = true
            ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &compress)
            var terminal: GhosttyTerminal?
            guard ghostty_snapshot_decoder_decode(decoder, &terminal) == GHOSTTY_SUCCESS else { return nil }
            return terminal
        }
        guard let terminal else { return nil }
        self.init(handle: terminal, scrollbackBytes: scrollbackBytes)
    }

    private init(handle: GhosttyTerminal, scrollbackBytes: Int) {
        self.handle = handle
        setScrollbackLimit(scrollbackBytes)
        // Keeps a sequence still being received, so a snapshot taken mid-sequence (a busy full-screen
        // program at quit) can still be saved.
        var continuation = 64 * 1024
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())

        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let data else { return }
            VTTerminal.owner(of: userdata).onWritePty?(UnsafeRawBufferPointer(start: data, count: length))
        }
        let titleChanged: GhosttyTerminalTitleChangedFn = { _, userdata in
            VTTerminal.owner(of: userdata).onTitleChanged?()
        }
        let pwdChanged: GhosttyTerminalPwdChangedFn = { _, userdata in
            VTTerminal.owner(of: userdata).onPwdChanged?()
        }
        let semanticPrompt: GhosttyTerminalSemanticPromptFn = { _, userdata, event in
            guard let event = event?.pointee else { return }
            let prompt: PromptEvent
            let owner = VTTerminal.owner(of: userdata)
            switch event.kind {
            case GHOSTTY_SEMANTIC_PROMPT_PROMPT_START:
                guard event.prompt_kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY else { return }
                owner.startCommandBlock()
                prompt = .promptStart
            case GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START:
                let command = event.command.text
                if let block = owner.commandBlocks.last, block.output == nil { block.output = owner.trackCursorRow() }
                prompt = .outputStart(command: command?.isEmpty == false ? command : nil)
            case GHOSTTY_SEMANTIC_PROMPT_COMMAND_END:
                if let block = owner.commandBlocks.last, block.output != nil { block.exitCode = event.has_exit_code ? event.exit_code : 0 }
                prompt = .commandEnd(exitCode: event.has_exit_code ? event.exit_code : nil)
            default:
                return
            }
            owner.onPrompt?(prompt)
        }
        let desktopNotification: GhosttyTerminalDesktopNotificationFn = { _, userdata, notification in
            guard let notification = notification?.pointee else { return }
            VTTerminal.owner(of: userdata).onDesktopNotification?(notification.title.text ?? "", notification.body.text ?? "")
        }
        let bell: GhosttyTerminalBellFn = { _, userdata in
            VTTerminal.owner(of: userdata).onBell?()
        }
        // Callback options take the function pointer itself as the value, not a pointer to it.
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwdChanged, to: UnsafeRawPointer.self))
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(semanticPrompt, to: UnsafeRawPointer.self))
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(desktopNotification, to: UnsafeRawPointer.self))
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
    }

    deinit {
        ghostty_terminal_free(handle)
    }

    /// The screen, history and parser state, for `init(snapshot:)` after a restart.
    func snapshot() -> Data? {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        let signpost = PerfSignposts.energy.beginInterval("snapshot", id: PerfSignposts.energy.makeSignpostID())
        defer { PerfSignposts.energy.endInterval("snapshot", signpost, "\(length) bytes") }
        guard ghostty_snapshot_encode_alloc(handle, nil, &bytes, &length) == GHOSTTY_SUCCESS, let bytes else { return nil }
        defer { ghostty_free(nil, bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    var title: String { string(for: GHOSTTY_TERMINAL_DATA_TITLE) }

    var pwd: String { string(for: GHOSTTY_TERMINAL_DATA_PWD) }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        ghostty_terminal_vt_write(handle, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        ghostty_terminal_resize(handle, cols, rows, cellWidth, cellHeight)
    }

    private func trackCursorRow() -> GhosttyTrackedGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate.y = UInt32(cursorPosition.y)
        var ref: GhosttyTrackedGridRef?
        guard ghostty_terminal_grid_ref_track(handle, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    /// A prompt that never ran a command (an empty line, a redraw) gives its block to the next one.
    private func startCommandBlock() {
        guard !isAlternateScreen, let prompt = trackCursorRow() else { return }
        if let last = commandBlocks.last, last.output == nil { commandBlocks.removeLast() }
        commandBlocks.append(CommandBlock(prompt: prompt))
        if commandBlocks.count > Self.commandBlockLimit { commandBlocks.removeFirst(commandBlocks.count - Self.commandBlockLimit) }
    }

    private static func screenRow(of ref: GhosttyTrackedGridRef) -> Int? {
        var point = GhosttyPointCoordinate()
        guard ghostty_tracked_grid_ref_point(ref, GHOSTTY_POINT_TAG_SCREEN, &point) == GHOSTTY_SUCCESS else { return nil }
        return Int(point.y)
    }

    /// Commands that ran, as screen rows from their prompt to the row before the next prompt,
    /// newest first, down to the first one ending above `top`.
    private func commandRanges(from top: Int) -> [(prompt: Int, output: Int, end: Int, exitCode: Int32)] {
        guard !isAlternateScreen else { return [] }
        var ranges: [(prompt: Int, output: Int, end: Int, exitCode: Int32)] = []
        var next = Int(scrollbar.total)
        for block in commandBlocks.reversed() {
            // A reference that scrolled out of the history has no row left.
            guard let prompt = Self.screenRow(of: block.prompt) else { break }
            defer { next = prompt }
            // A running command has no bar yet: ssh or a server would hold one open down the screen.
            guard let exitCode = block.exitCode, let output = block.output.flatMap(Self.screenRow(of:)) else { continue }
            ranges.append((prompt, output, max(prompt, next - 1), exitCode))
            if prompt < top { break }
        }
        return ranges
    }

    /// Bars of the finished commands in the viewport: rows (clamped to it) and the exit code.
    func visibleCommandMarks() -> [TerminalCommandMark] {
        let scrollbar = self.scrollbar
        let top = Int(scrollbar.offset)
        let bottom = top + Int(scrollbar.len) - 1
        return commandRanges(from: top).compactMap { range in
            guard range.end >= top, range.prompt <= bottom else { return nil }
            return TerminalCommandMark(rows: (max(range.prompt, top) - top)...(min(range.end, bottom) - top), exitCode: range.exitCode)
        }
    }

    /// Selects the output of the command whose bar covers this viewport row. False when none does.
    func selectCommandOutput(atViewportRow row: Int) -> Bool {
        let screenRow = Int(scrollbar.offset) + row
        guard let range = commandRanges(from: screenRow).first(where: { ($0.prompt...$0.end).contains(screenRow) }),
              range.output <= range.end else { return false }
        guard var selection = selection(GHOSTTY_POINT_TAG_SCREEN, from: (0, range.output), to: (columns - 1, range.end)) else { return false }
        return ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    /// The grid reference of a cell; nil outside the grid.
    func gridRef(_ tag: GhosttyPointTag, x: Int = 0, y: Int) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = tag
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: x), y: UInt32(clamping: y))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        return ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private func selection(_ tag: GhosttyPointTag, from start: (x: Int, y: Int), to end: (x: Int, y: Int)) -> GhosttySelection? {
        guard let start = gridRef(tag, x: start.x, y: start.y), let end = gridRef(tag, x: end.x, y: end.y) else { return nil }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = start
        selection.end = end
        return selection
    }

    private func string(for data: GhosttyTerminalData) -> String {
        var value = GhosttyString()
        guard ghostty_terminal_get(handle, data, &value) == GHOSTTY_SUCCESS else { return "" }
        return value.text ?? ""
    }

    private static func owner(of userdata: UnsafeMutableRawPointer?) -> VTTerminal {
        Unmanaged<VTTerminal>.fromOpaque(userdata!).takeUnretainedValue()
    }
}

extension GhosttyString {
    var text: String? {
        ptr.flatMap { String(bytes: UnsafeBufferPointer(start: $0, count: len), encoding: .utf8) }
    }
}

struct VTColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

/// One cell, valid only inside the `forEachCell` callback (`codepoints` points into reused storage).
struct VTCell {
    enum Width {
        case narrow, wide, spacer
    }

    var width = Width.narrow
    var codepoints = UnsafeBufferPointer<UInt32>(start: nil, count: 0)
    var foreground: VTColor?
    var background: VTColor?
    var bold = false
    var italic = false
    var faint = false
    var inverse = false
    var invisible = false
    var underline = false
    var strikethrough = false
}

struct VTCursor: Equatable {
    enum Style {
        case block, bar, underline, hollow
    }

    var x: Int
    var y: Int
    var visible: Bool
    var blinking: Bool
    var style: Style
}

/// A renderer's private copy of the visible screen. Only `beginUpdate` touches the terminal, so the
/// renderer holds the terminal lock for that call alone and reads everything else unlocked.
final class VTRenderState {
    enum Dirty {
        case clean, partial, full
    }

    private let state: GhosttyRenderState
    private var rows: GhosttyRenderStateRowIterator
    private var cells: GhosttyRenderStateRowCells
    private static let codepointCapacity = 32
    private let codepoints = UnsafeMutablePointer<UInt32>.allocate(capacity: VTRenderState.codepointCapacity)

    init() {
        var state: GhosttyRenderState?
        var rows: GhosttyRenderStateRowIterator?
        var cells: GhosttyRenderStateRowCells?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS, let state,
              ghostty_render_state_row_iterator_new(nil, &rows) == GHOSTTY_SUCCESS, let rows,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS, let cells else {
            fatalError("libghostty-vt could not allocate a render state")
        }
        self.state = state
        self.rows = rows
        self.cells = cells
        // One row past each edge of the viewport, for scrolling by less than a row.
        var overscan = GhosttyRenderStateOverscan(above: 1, below: 1)
        ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPTION_OVERSCAN, &overscan)
    }

    deinit {
        ghostty_render_state_row_cells_free(cells)
        ghostty_render_state_row_iterator_free(rows)
        ghostty_render_state_free(state)
        codepoints.deallocate()
    }

    /// Needs exclusive access to the terminal: call it inside `TerminalSession.withLockedTerminal`.
    func beginUpdate(from terminal: VTTerminal) {
        ghostty_render_state_begin_update(state, terminal.handle)
    }

    func endUpdate() {
        ghostty_render_state_end_update(state)
    }

    func clean() {
        ghostty_render_state_clean(state)
    }

    var dirty: Dirty {
        var value = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &value)
        switch value {
        case GHOSTTY_RENDER_STATE_DIRTY_PARTIAL: return .partial
        case GHOSTTY_RENDER_STATE_DIRTY_FULL: return .full
        default: return .clean
        }
    }

    var size: (cols: Int, rows: Int) {
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
        return (Int(cols), Int(rows))
    }

    var colors: (background: VTColor, foreground: VTColor, cursor: VTColor?) {
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        return (
            VTColor(r: colors.background.r, g: colors.background.g, b: colors.background.b),
            VTColor(r: colors.foreground.r, g: colors.foreground.g, b: colors.foreground.b),
            colors.cursor_has_value ? VTColor(r: colors.cursor.r, g: colors.cursor.g, b: colors.cursor.b) : nil
        )
    }

    var cursor: VTCursor? {
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor) == GHOSTTY_SUCCESS,
              cursor.viewport_has_value else { return nil }
        let style: VTCursor.Style
        switch cursor.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: style = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: style = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: style = .hollow
        default: style = .block
        }
        // The tail of a wide character reports the cell after the one the cursor sits on.
        let x = Int(cursor.viewport_x) - (cursor.wide_tail ? 1 : 0)
        return VTCursor(x: x, y: Int(cursor.viewport_y), visible: cursor.visible, blinking: cursor.blinking, style: style)
    }

    /// Rows captured past the top and bottom of the viewport by the last update (0 or 1 each).
    var overscan: (above: Int, below: Int) {
        var overscan = GhosttyRenderStateOverscan(above: 0, below: 0)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_OVERSCAN, &overscan)
        return (Int(overscan.above), Int(overscan.below))
    }

    /// Visits every row top to bottom with its viewport row (-1 and `rows` for the overscan rows),
    /// dirty flag and selected columns; `body` may call `forEachCell` for the row it is given.
    func forEachRow(_ body: (_ y: Int, _ dirty: Bool, _ selection: ClosedRange<Int>?) -> Void) {
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows) == GHOSTTY_SUCCESS else { return }
        while ghostty_render_state_row_iterator_next(rows) {
            var y: Int32 = 0
            ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, &y)
            var dirty = false
            ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &dirty)
            var selection = GhosttyRenderStateRowSelection()
            selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let selected = ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
            body(Int(y), dirty, selected ? Int(selection.start_x)...Int(selection.end_x) : nil)
        }
    }

    func forEachCell(_ body: (Int, VTCell) -> Void) {
        guard ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS else { return }
        var x = 0
        while ghostty_render_state_row_cells_next(cells) {
            var cell = VTCell()
            var raw: GhosttyCell = 0
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            switch wide {
            case GHOSTTY_CELL_WIDE_WIDE: cell.width = .wide
            case GHOSTTY_CELL_WIDE_SPACER_TAIL, GHOSTTY_CELL_WIDE_SPACER_HEAD: cell.width = .spacer
            default: cell.width = .narrow
            }
            var length: UInt32 = 0
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
            if length > 0, length <= Self.codepointCapacity {
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints)
                cell.codepoints = UnsafeBufferPointer(start: codepoints, count: Int(length))
            }
            var styled = false
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled)
            if styled {
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                cell.bold = style.bold
                cell.italic = style.italic
                cell.faint = style.faint
                cell.inverse = style.inverse
                cell.invisible = style.invisible
                cell.underline = style.underline != 0
                cell.strikethrough = style.strikethrough
                var color = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color) == GHOSTTY_SUCCESS {
                    cell.foreground = VTColor(r: color.r, g: color.g, b: color.b)
                }
            }
            // Erased cells can carry a background without any style, so this is read for every cell.
            var background = GhosttyColorRgb()
            if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background) == GHOSTTY_SUCCESS {
                cell.background = VTColor(r: background.r, g: background.g, b: background.b)
            }
            body(x, cell)
            x += 1
        }
    }
}

extension VTTerminal {
    /// Default colors, used wherever a program has not set its own.
    func setDefaultColors(background: VTColor, foreground: VTColor, cursor: VTColor) {
        var background = GhosttyColorRgb(r: background.r, g: background.g, b: background.b)
        var foreground = GhosttyColorRgb(r: foreground.r, g: foreground.g, b: foreground.b)
        var cursor = GhosttyColorRgb(r: cursor.r, g: cursor.g, b: cursor.b)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)
    }

    /// Replaces the 16 ANSI colors; the 240 extended ones keep libghostty's defaults.
    func setPalette(_ colors: [VTColor]) {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBytes { _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, $0.baseAddress) }
        for (index, color) in colors.prefix(16).enumerated() {
            palette[index] = GhosttyColorRgb(r: color.r, g: color.g, b: color.b)
        }
        palette.withUnsafeBytes { _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress) }
    }

    func mode(_ number: UInt16) -> Bool {
        var config = GhosttyTerminalModeConfig()
        config.mode = ghostty_mode_new(number, false)
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    /// Whether the running program asked for mouse reports, so clicks belong to it, not to selection.
    var tracksMouse: Bool {
        var tracking = false
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    /// Whether the program asked the kitty keyboard protocol for key releases; nothing else reports them.
    var reportsKeyReleases: Bool {
        var flags: GhosttyKittyKeyFlags = 0
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        return flags & GhosttyKittyKeyFlags(GHOSTTY_KITTY_KEY_REPORT_EVENTS) != 0
    }

    var isAlternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen != GHOSTTY_TERMINAL_SCREEN_PRIMARY
    }

    /// Whether the viewport shows the oldest history line, and whether it follows the newest output.
    var scrollEdges: (atTop: Bool, atBottom: Bool) {
        var following = true
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &following)
        return (scrollbar.offset == 0, following)
    }

    /// All zero when the terminal cannot report it.
    private var scrollbar: GhosttyTerminalScrollbar {
        var scrollbar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar)
        return scrollbar
    }

    /// Changes whenever history compression has new work; only equality means anything.
    var compressionActivity: UInt64 {
        var activity: UInt64 = 0
        ghostty_terminal_compression_activity(handle, &activity)
        return activity
    }

    /// One bounded step of history compression. True once the pass has nothing left to do.
    func compressHistoryStep() -> Bool {
        var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE
        ghostty_terminal_compress(handle, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &result)
        return result != GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING
    }

    /// History past this many bytes is dropped, oldest first.
    func setScrollbackLimit(_ bytes: Int) {
        var bytes = bytes
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
    }

    /// Negative scrolls back into history.
    func scrollViewport(by rows: Int) {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        scroll.value.delta = rows
        ghostty_terminal_scroll_viewport(handle, scroll)
    }

    /// Scrolls the nearest shell prompt above (or below) the top of the viewport to the top.
    /// Returns false when there is none.
    @discardableResult
    func scrollToPrompt(older: Bool) -> Bool {
        let scrollbar = self.scrollbar
        let step = older ? -1 : 1
        var row = Int(scrollbar.offset) + step
        while row >= 0, row < Int(scrollbar.total) {
            if isPromptRow(row) {
                var scroll = GhosttyTerminalScrollViewport()
                scroll.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
                scroll.value.row = row
                ghostty_terminal_scroll_viewport(handle, scroll)
                return true
            }
            row += step
        }
        return false
    }

    /// Whether a screen row (history included, oldest first) starts a shell prompt.
    private func isPromptRow(_ screenRow: Int) -> Bool {
        var row: GhosttyRow = 0
        guard var ref = gridRef(GHOSTTY_POINT_TAG_SCREEN, y: screenRow),
              ghostty_grid_ref_row(&ref, &row) == GHOSTTY_SUCCESS else { return false }
        var prompt = GHOSTTY_ROW_SEMANTIC_NONE
        ghostty_row_get(row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &prompt)
        return prompt == GHOSTTY_ROW_SEMANTIC_PROMPT
    }

    func scrollToBottom() {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(handle, scroll)
    }

    var selectionText: String? {
        plainText(of: nil, unwrap: true, trim: true)
    }

    /// Plain text of `selection`, or of the terminal's own selection when nil.
    private func plainText(of selection: UnsafePointer<GhosttySelection>?, unwrap: Bool, trim: Bool) -> String? {
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = unwrap
        options.trim = trim
        options.selection = selection
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(handle, nil, options, &bytes, &length) == GHOSTTY_SUCCESS,
              let bytes else { return nil }
        defer { ghostty_free(nil, bytes, length) }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8)
    }

    /// Plain text of the active screen, the rows a program draws on, whatever the viewport shows.
    var activeScreenText: String? { screenText(GHOSTTY_POINT_TAG_ACTIVE) }

    /// Plain text of the rows in view, scrollback included when scrolled up.
    var viewportText: String? { screenText(GHOSTTY_POINT_TAG_VIEWPORT) }

    private func screenText(_ area: GhosttyPointTag) -> String? {
        let cols = columns, rows = self.rows
        guard cols > 0, rows > 0, var selection = selection(area, from: (0, 0), to: (cols - 1, rows - 1)) else { return nil }
        return withUnsafePointer(to: &selection) { plainText(of: $0, unwrap: false, trim: true) }
    }

    func clearSelection() {
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    func selectAll() {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_all(handle, &selection) == GHOSTTY_SUCCESS else { return }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    /// Plain text of the logical line through a viewport row, soft-wrapped rows included, and the
    /// viewport row it starts on (negative above the viewport).
    func line(row: Int) -> (text: String, top: Int)? {
        var options = GhosttyTerminalSelectLineOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
        guard let ref = gridRef(GHOSTTY_POINT_TAG_VIEWPORT, y: row) else { return nil }
        options.ref = ref
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        var rowPoint = GhosttyPointCoordinate()
        var startPoint = GhosttyPointCoordinate()
        guard ghostty_terminal_select_line(handle, &options, &selection) == GHOSTTY_SUCCESS,
              ghostty_terminal_point_from_grid_ref(handle, &options.ref, GHOSTTY_POINT_TAG_SCREEN, &rowPoint) == GHOSTTY_SUCCESS,
              ghostty_terminal_point_from_grid_ref(handle, &selection.start, GHOSTTY_POINT_TAG_SCREEN, &startPoint) == GHOSTTY_SUCCESS
        else { return nil }
        // The selection trims the line's leading blanks: put them back so characters keep their columns.
        return withUnsafePointer(to: &selection, { plainText(of: $0, unwrap: true, trim: false) }).map {
            (String(repeating: " ", count: Int(selection.start.x)) + $0, row - (Int(rowPoint.y) - Int(startPoint.y)))
        }
    }

    /// The OSC 8 hyperlink of a viewport cell, and the columns carrying it on each row of the run of
    /// consecutive rows that do.
    func hyperlink(row: Int, column: Int) -> (uri: String, rows: [Int: ClosedRange<Int>])? {
        var buffer = [UInt8](repeating: 0, count: 256)
        func uri(_ x: Int, _ y: Int) -> [UInt8]? {
            guard var ref = gridRef(GHOSTTY_POINT_TAG_VIEWPORT, x: x, y: y) else { return nil }
            var cell: GhosttyCell = 0
            var linked = false
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS,
                  ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &linked) == GHOSTTY_SUCCESS, linked else { return nil }
            var length = 0
            if ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length) == GHOSTTY_OUT_OF_SPACE {
                buffer = [UInt8](repeating: 0, count: length)
                guard ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length) == GHOSTTY_SUCCESS else { return nil }
            }
            return length > 0 ? Array(buffer[..<length]) : nil
        }
        guard let target = uri(column, row), let text = String(bytes: target, encoding: .utf8) else { return nil }
        let columns = self.columns
        func span(_ y: Int) -> ClosedRange<Int>? {
            var gridRow: GhosttyRow = 0
            var linked = false
            guard var ref = gridRef(GHOSTTY_POINT_TAG_VIEWPORT, y: y), ghostty_grid_ref_row(&ref, &gridRow) == GHOSTTY_SUCCESS,
                  ghostty_row_get(gridRow, GHOSTTY_ROW_DATA_HYPERLINK, &linked) == GHOSTTY_SUCCESS, linked,
                  let first = (0..<columns).first(where: { uri($0, y) == target }) else { return nil }
            return first...(first..<columns).last { uri($0, y) == target }!
        }
        var rows: [Int: ClosedRange<Int>] = [:]
        var y = row
        while y >= 0, let found = span(y) {
            rows[y] = found
            y -= 1
        }
        y = row + 1
        while y < self.rows, let found = span(y) {
            rows[y] = found
            y += 1
        }
        return (text, rows)
    }

    var columns: Int {
        var columns: UInt16 = 0
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &columns)
        return Int(columns)
    }

    var rows: Int {
        var rows: UInt16 = 0
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        return Int(rows)
    }

    var cursorPosition: (x: Int, y: Int) {
        var x: UInt16 = 0
        var y: UInt16 = 0
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        return (Int(x), Int(y))
    }

    /// Bytes for a paste, framed for bracketed paste when the program enabled it. Nil when the text
    /// could run commands by itself (a newline outside bracketed paste), so the caller can confirm.
    func encodePaste(_ text: String, allowUnsafe: Bool) -> [UInt8]? {
        var data = Array(text.utf8CString.dropLast())
        let bracketed = mode(2004)
        guard allowUnsafe || ghostty_paste_is_safe(data, data.count) || bracketed else { return nil }
        var written = 0
        ghostty_paste_encode(&data, data.count, bracketed, nil, 0, &written)
        var output = [CChar](repeating: 0, count: max(written, data.count + 16))
        guard ghostty_paste_encode(&data, data.count, bracketed, &output, output.count, &written) == GHOSTTY_SUCCESS else { return nil }
        return output[..<written].map { UInt8(bitPattern: $0) }
    }

    /// Focus report for programs that enabled mode 1004; empty otherwise.
    func encodeFocus(_ gained: Bool) -> [UInt8] {
        guard mode(1004) else { return [] }
        var buffer = [CChar](repeating: 0, count: 8)
        var written = 0
        guard ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, &buffer, buffer.count, &written) == GHOSTTY_SUCCESS else { return [] }
        return buffer[..<written].map { UInt8(bitPattern: $0) }
    }
}

/// Keyboard and mouse encoders. Every call reads modes from the terminal, so it runs under the
/// terminal lock.
final class VTInputEncoder {
    enum MouseAction {
        case press, release, motion
    }

    enum MouseButton: Int32 {
        case none = 0, left = 1, right = 2, middle = 3, wheelUp = 4, wheelDown = 5
    }

    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    private let mouseEncoder: GhosttyMouseEncoder
    private let mouseEvent: GhosttyMouseEvent
    private var buffer = [CChar](repeating: 0, count: 128)

    init() {
        var keyEncoder: GhosttyKeyEncoder?
        var keyEvent: GhosttyKeyEvent?
        var mouseEncoder: GhosttyMouseEncoder?
        var mouseEvent: GhosttyMouseEvent?
        guard ghostty_key_encoder_new(nil, &keyEncoder) == GHOSTTY_SUCCESS, let keyEncoder,
              ghostty_key_event_new(nil, &keyEvent) == GHOSTTY_SUCCESS, let keyEvent,
              ghostty_mouse_encoder_new(nil, &mouseEncoder) == GHOSTTY_SUCCESS, let mouseEncoder,
              ghostty_mouse_event_new(nil, &mouseEvent) == GHOSTTY_SUCCESS, let mouseEvent else {
            fatalError("libghostty-vt could not allocate input encoders")
        }
        self.keyEncoder = keyEncoder
        self.keyEvent = keyEvent
        self.mouseEncoder = mouseEncoder
        self.mouseEvent = mouseEvent
    }

    deinit {
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
    }

    /// `text` is what the key typed after IME and layout processing, if anything.
    /// `optionIsMeta`: Option is Alt for this key, so it prefixes Escape rather than typing a character.
    func encodeKey(_ event: NSEvent, released: Bool, text: String?, optionIsMeta: Bool, terminal: VTTerminal) -> [UInt8] {
        ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal.handle)
        var optionAsAlt = optionIsMeta ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_setopt(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)
        ghostty_key_event_set_action(keyEvent, released ? GHOSTTY_KEY_ACTION_RELEASE : event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(keyEvent, Self.key(for: event.keyCode))
        let mods = Self.mods(event.modifierFlags)
        ghostty_key_event_set_mods(keyEvent, mods)
        // Option and Shift that produced the text are consumed: Option-E on a French layout types
        // a character, not Alt-E.
        let consumed = text == nil ? 0 : mods & GhosttyMods(optionIsMeta ? GHOSTTY_MODS_SHIFT : GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_ALT)
        ghostty_key_event_set_consumed_mods(keyEvent, consumed)
        ghostty_key_event_set_composing(keyEvent, false)
        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        ghostty_key_event_set_unshifted_codepoint(keyEvent, unshifted)
        let utf8 = Array((text ?? "").utf8)
        return utf8.withUnsafeBufferPointer { bytes in
            bytes.withMemoryRebound(to: CChar.self) { chars in
                ghostty_key_event_set_utf8(keyEvent, chars.baseAddress, chars.count)
                return encode { ghostty_key_encoder_encode(keyEncoder, keyEvent, $0, $1, $2) }
            }
        }
    }

    /// `position` is in pixels from the top left of the view, padding included.
    func encodeMouse(
        _ action: MouseAction, button: MouseButton, position: CGPoint, modifiers: NSEvent.ModifierFlags,
        geometry: (width: Int, height: Int, cellWidth: Int, cellHeight: Int, paddingX: Int, paddingY: Int),
        terminal: VTTerminal
    ) -> [UInt8] {
        ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal.handle)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(geometry.width)
        size.screen_height = UInt32(geometry.height)
        size.cell_width = UInt32(geometry.cellWidth)
        size.cell_height = UInt32(geometry.cellHeight)
        size.padding_left = UInt32(geometry.paddingX)
        size.padding_right = UInt32(geometry.paddingX)
        size.padding_top = UInt32(geometry.paddingY)
        size.padding_bottom = UInt32(geometry.paddingY)
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        let mouseAction = switch action {
        case .press: GHOSTTY_MOUSE_ACTION_PRESS
        case .release: GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: GHOSTTY_MOUSE_ACTION_MOTION
        }
        ghostty_mouse_event_set_action(mouseEvent, mouseAction)
        if button == .none {
            ghostty_mouse_event_clear_button(mouseEvent)
        } else {
            ghostty_mouse_event_set_button(mouseEvent, GhosttyMouseButton(rawValue: button.rawValue))
        }
        ghostty_mouse_event_set_mods(mouseEvent, Self.mods(modifiers))
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(position.x), y: Float(position.y)))
        return encode { ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, $0, $1, $2) }
    }

    private func encode(_ body: (UnsafeMutablePointer<CChar>, Int, UnsafeMutablePointer<Int>) -> GhosttyResult) -> [UInt8] {
        var written = 0
        var result = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count, &written) }
        if result == GHOSTTY_OUT_OF_SPACE {
            buffer = [CChar](repeating: 0, count: written)
            result = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count, &written) }
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return buffer[..<written].map { UInt8(bitPattern: $0) }
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: Int32 = 0
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS_LOCK }
        return GhosttyMods(mods)
    }

    /// macOS virtual key codes to physical keys, from Ghostty's keycodes table.
    private static func key(for keyCode: UInt16) -> GhosttyKey {
        switch keyCode {
        case 0x00: return GHOSTTY_KEY_A
        case 0x01: return GHOSTTY_KEY_S
        case 0x02: return GHOSTTY_KEY_D
        case 0x03: return GHOSTTY_KEY_F
        case 0x04: return GHOSTTY_KEY_H
        case 0x05: return GHOSTTY_KEY_G
        case 0x06: return GHOSTTY_KEY_Z
        case 0x07: return GHOSTTY_KEY_X
        case 0x08: return GHOSTTY_KEY_C
        case 0x09: return GHOSTTY_KEY_V
        case 0x0A: return GHOSTTY_KEY_INTL_BACKSLASH
        case 0x0B: return GHOSTTY_KEY_B
        case 0x0C: return GHOSTTY_KEY_Q
        case 0x0D: return GHOSTTY_KEY_W
        case 0x0E: return GHOSTTY_KEY_E
        case 0x0F: return GHOSTTY_KEY_R
        case 0x10: return GHOSTTY_KEY_Y
        case 0x11: return GHOSTTY_KEY_T
        case 0x12: return GHOSTTY_KEY_DIGIT_1
        case 0x13: return GHOSTTY_KEY_DIGIT_2
        case 0x14: return GHOSTTY_KEY_DIGIT_3
        case 0x15: return GHOSTTY_KEY_DIGIT_4
        case 0x16: return GHOSTTY_KEY_DIGIT_6
        case 0x17: return GHOSTTY_KEY_DIGIT_5
        case 0x18: return GHOSTTY_KEY_EQUAL
        case 0x19: return GHOSTTY_KEY_DIGIT_9
        case 0x1A: return GHOSTTY_KEY_DIGIT_7
        case 0x1B: return GHOSTTY_KEY_MINUS
        case 0x1C: return GHOSTTY_KEY_DIGIT_8
        case 0x1D: return GHOSTTY_KEY_DIGIT_0
        case 0x1E: return GHOSTTY_KEY_BRACKET_RIGHT
        case 0x1F: return GHOSTTY_KEY_O
        case 0x20: return GHOSTTY_KEY_U
        case 0x21: return GHOSTTY_KEY_BRACKET_LEFT
        case 0x22: return GHOSTTY_KEY_I
        case 0x23: return GHOSTTY_KEY_P
        case 0x24: return GHOSTTY_KEY_ENTER
        case 0x25: return GHOSTTY_KEY_L
        case 0x26: return GHOSTTY_KEY_J
        case 0x27: return GHOSTTY_KEY_QUOTE
        case 0x28: return GHOSTTY_KEY_K
        case 0x29: return GHOSTTY_KEY_SEMICOLON
        case 0x2A: return GHOSTTY_KEY_BACKSLASH
        case 0x2B: return GHOSTTY_KEY_COMMA
        case 0x2C: return GHOSTTY_KEY_SLASH
        case 0x2D: return GHOSTTY_KEY_N
        case 0x2E: return GHOSTTY_KEY_M
        case 0x2F: return GHOSTTY_KEY_PERIOD
        case 0x30: return GHOSTTY_KEY_TAB
        case 0x31: return GHOSTTY_KEY_SPACE
        case 0x32: return GHOSTTY_KEY_BACKQUOTE
        case 0x33: return GHOSTTY_KEY_BACKSPACE
        case 0x35: return GHOSTTY_KEY_ESCAPE
        case 0x36: return GHOSTTY_KEY_META_RIGHT
        case 0x37: return GHOSTTY_KEY_META_LEFT
        case 0x38: return GHOSTTY_KEY_SHIFT_LEFT
        case 0x39: return GHOSTTY_KEY_CAPS_LOCK
        case 0x3A: return GHOSTTY_KEY_ALT_LEFT
        case 0x3B: return GHOSTTY_KEY_CONTROL_LEFT
        case 0x3C: return GHOSTTY_KEY_SHIFT_RIGHT
        case 0x3D: return GHOSTTY_KEY_ALT_RIGHT
        case 0x3E: return GHOSTTY_KEY_CONTROL_RIGHT
        case 0x40: return GHOSTTY_KEY_F17
        case 0x41: return GHOSTTY_KEY_NUMPAD_DECIMAL
        case 0x43: return GHOSTTY_KEY_NUMPAD_MULTIPLY
        case 0x45: return GHOSTTY_KEY_NUMPAD_ADD
        case 0x47: return GHOSTTY_KEY_NUM_LOCK
        case 0x48: return GHOSTTY_KEY_AUDIO_VOLUME_UP
        case 0x49: return GHOSTTY_KEY_AUDIO_VOLUME_DOWN
        case 0x4A: return GHOSTTY_KEY_AUDIO_VOLUME_MUTE
        case 0x4B: return GHOSTTY_KEY_NUMPAD_DIVIDE
        case 0x4C: return GHOSTTY_KEY_NUMPAD_ENTER
        case 0x4E: return GHOSTTY_KEY_NUMPAD_SUBTRACT
        case 0x4F: return GHOSTTY_KEY_F18
        case 0x50: return GHOSTTY_KEY_F19
        case 0x51: return GHOSTTY_KEY_NUMPAD_EQUAL
        case 0x52: return GHOSTTY_KEY_NUMPAD_0
        case 0x53: return GHOSTTY_KEY_NUMPAD_1
        case 0x54: return GHOSTTY_KEY_NUMPAD_2
        case 0x55: return GHOSTTY_KEY_NUMPAD_3
        case 0x56: return GHOSTTY_KEY_NUMPAD_4
        case 0x57: return GHOSTTY_KEY_NUMPAD_5
        case 0x58: return GHOSTTY_KEY_NUMPAD_6
        case 0x59: return GHOSTTY_KEY_NUMPAD_7
        case 0x5A: return GHOSTTY_KEY_F20
        case 0x5B: return GHOSTTY_KEY_NUMPAD_8
        case 0x5C: return GHOSTTY_KEY_NUMPAD_9
        case 0x5D: return GHOSTTY_KEY_INTL_YEN
        case 0x5E: return GHOSTTY_KEY_INTL_RO
        case 0x5F: return GHOSTTY_KEY_NUMPAD_COMMA
        case 0x60: return GHOSTTY_KEY_F5
        case 0x61: return GHOSTTY_KEY_F6
        case 0x62: return GHOSTTY_KEY_F7
        case 0x63: return GHOSTTY_KEY_F3
        case 0x64: return GHOSTTY_KEY_F8
        case 0x65: return GHOSTTY_KEY_F9
        case 0x67: return GHOSTTY_KEY_F11
        case 0x69: return GHOSTTY_KEY_F13
        case 0x6A: return GHOSTTY_KEY_F16
        case 0x6B: return GHOSTTY_KEY_F14
        case 0x6D: return GHOSTTY_KEY_F10
        case 0x6E: return GHOSTTY_KEY_CONTEXT_MENU
        case 0x6F: return GHOSTTY_KEY_F12
        case 0x71: return GHOSTTY_KEY_F15
        case 0x72: return GHOSTTY_KEY_INSERT
        case 0x73: return GHOSTTY_KEY_HOME
        case 0x74: return GHOSTTY_KEY_PAGE_UP
        case 0x75: return GHOSTTY_KEY_DELETE
        case 0x76: return GHOSTTY_KEY_F4
        case 0x77: return GHOSTTY_KEY_END
        case 0x78: return GHOSTTY_KEY_F2
        case 0x79: return GHOSTTY_KEY_PAGE_DOWN
        case 0x7A: return GHOSTTY_KEY_F1
        case 0x7B: return GHOSTTY_KEY_ARROW_LEFT
        case 0x7C: return GHOSTTY_KEY_ARROW_RIGHT
        case 0x7D: return GHOSTTY_KEY_ARROW_DOWN
        case 0x7E: return GHOSTTY_KEY_ARROW_UP
        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}

/// Click, double-click (word), triple-click (line) and drag selection, interpreted by
/// libghostty-vt and installed as the terminal's selection. Runs under the terminal lock.
final class VTSelectionGesture {
    enum Phase {
        case press, drag, release
    }

    private let gesture: GhosttySelectionGesture
    private let press: GhosttySelectionGestureEvent
    private let drag: GhosttySelectionGestureEvent
    private let release: GhosttySelectionGestureEvent

    init() {
        var gesture: GhosttySelectionGesture?
        var press: GhosttySelectionGestureEvent?
        var drag: GhosttySelectionGestureEvent?
        var release: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_new(nil, &gesture) == GHOSTTY_SUCCESS, let gesture,
              ghostty_selection_gesture_event_new(nil, &press, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) == GHOSTTY_SUCCESS, let press,
              ghostty_selection_gesture_event_new(nil, &drag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) == GHOSTTY_SUCCESS, let drag,
              ghostty_selection_gesture_event_new(nil, &release, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) == GHOSTTY_SUCCESS, let release else {
            fatalError("libghostty-vt could not allocate a selection gesture")
        }
        self.gesture = gesture
        self.press = press
        self.drag = drag
        self.release = release
    }

    deinit {
        ghostty_selection_gesture_event_free(release)
        ghostty_selection_gesture_event_free(drag)
        ghostty_selection_gesture_event_free(press)
        ghostty_selection_gesture_free(gesture, nil)
    }

    /// `cell` is the viewport cell under the pointer, `position` the pointer in pixels from the
    /// view's top left.
    func handle(
        _ phase: Phase, cell: (x: Int, y: Int), position: CGPoint, rectangle: Bool,
        geometry: (columns: Int, cellWidth: Int, paddingX: Int, height: Int), terminal: VTTerminal
    ) {
        guard var ref = terminal.gridRef(GHOSTTY_POINT_TAG_VIEWPORT, x: cell.x, y: cell.y) else { return }
        let event = switch phase {
        case .press: press
        case .drag: drag
        case .release: release
        }
        var surface = GhosttySurfacePosition(x: position.x, y: position.y)
        var rect = rectangle
        var time = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var interval = UInt64(NSEvent.doubleClickInterval * 1_000_000_000)
        var shape = GhosttySelectionGestureGeometry(
            columns: UInt32(geometry.columns), cell_width: UInt32(geometry.cellWidth),
            padding_left: UInt32(geometry.paddingX), screen_height: UInt32(geometry.height)
        )
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface)
        if phase == .press {
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
        }
        if phase == .drag {
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &shape)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)
        }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        if ghostty_selection_gesture_event(gesture, terminal.handle, event, &selection) == GHOSTTY_SUCCESS {
            ghostty_terminal_set(terminal.handle, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        } else if phase == .press {
            terminal.clearSelection()
        }
    }
}

/// Find in the terminal, scrollback included. Scanning (`tick`) only reads the search's own copy,
/// so it runs without the terminal lock; `setNeedle`, `feed` and `step` need it. The current match
/// becomes the terminal's selection, so it is drawn and scrolled into view like one.
final class VTSearch: @unchecked Sendable {
    enum Progress {
        case running, feedRequired, complete
    }

    private let search: GhosttySearch

    init?(terminal: VTTerminal) {
        var search: GhosttySearch?
        guard ghostty_search_new(nil, &search, terminal.handle) == GHOSTTY_SUCCESS, let search else { return nil }
        self.search = search
    }

    deinit {
        ghostty_search_free(search)
    }

    /// Restarts the search (ASCII letters ignore case); an empty needle stops it.
    func setNeedle(_ needle: String) {
        guard !needle.isEmpty else {
            ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
            return
        }
        Array(needle.utf8).withUnsafeBufferPointer { buffer in
            var string = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
            ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, &string)
        }
        ghostty_search_feed(search)
    }

    func feed() {
        ghostty_search_feed(search)
    }

    func tick() -> Progress {
        var status = GHOSTTY_SEARCH_STATUS_RUNNING
        ghostty_search_tick(search, &status)
        switch status {
        case GHOSTTY_SEARCH_STATUS_COMPLETE: return .complete
        case GHOSTTY_SEARCH_STATUS_FEED_REQUIRED: return .feedRequired
        default: return .running
        }
    }

    var matchCount: Int {
        var total = 0
        ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        return total
    }

    /// Every match on screen as row and column spans, after catching up with new output. Needs the
    /// terminal lock.
    func viewportMatches(terminal: VTTerminal) -> [(row: Int, columns: ClosedRange<Int>)] {
        ghostty_search_feed(search)
        var buffer = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
        ghostty_search_get(search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer)
        guard buffer.len > 0 else { return [] }
        var empty = GhosttySelection()
        empty.size = MemoryLayout<GhosttySelection>.size
        var matches = [GhosttySelection](repeating: empty, count: buffer.len)
        let fetched = matches.withUnsafeMutableBufferPointer { storage in
            buffer = GhosttySelectionBuffer(ptr: storage.baseAddress, cap: storage.count, len: 0)
            return ghostty_search_get(search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer) == GHOSTTY_SUCCESS
        }
        guard fetched else { return [] }
        let columns = terminal.columns
        let rows = terminal.rows
        var spans: [(row: Int, columns: ClosedRange<Int>)] = []
        for var match in matches.prefix(buffer.len) {
            var start = GhosttyPointCoordinate()
            var end = GhosttyPointCoordinate()
            // Matches on the viewport's pages but scrolled out of view fail to convert: skip them.
            guard ghostty_terminal_point_from_grid_ref(terminal.handle, &match.start, GHOSTTY_POINT_TAG_VIEWPORT, &start) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(terminal.handle, &match.end, GHOSTTY_POINT_TAG_VIEWPORT, &end) == GHOSTTY_SUCCESS
            else { continue }
            for row in Int(start.y)...max(Int(start.y), Int(end.y)) where row < rows {
                let first = row == Int(start.y) ? Int(start.x) : 0
                let last = row == Int(end.y) ? Int(end.x) : columns - 1
                if first <= last { spans.append((row, first...last)) }
            }
        }
        return spans
    }

    /// Moves to the next match toward older output, or toward newer output, wrapping around.
    func step(older: Bool, terminal: VTTerminal) {
        ghostty_search_set(search, older ? GHOSTTY_SEARCH_OPT_SELECT_NEXT : GHOSTTY_SEARCH_OPT_SELECT_PREV, nil)
        var match = GhosttySelection()
        match.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match) == GHOSTTY_SUCCESS else { return }
        ghostty_terminal_set(terminal.handle, GHOSTTY_TERMINAL_OPT_SELECTION, &match)
    }
}
