import CoreText

/// One textured (or solid) quad drawn by the text pass. Layout matches `GlyphInstance` in
/// TerminalShaders.metal: keep both in sync.
struct GlyphInstance {
    static let solid: UInt8 = 1
    static let cursorGlyph: UInt8 = 2

    var grid: SIMD2<UInt16>
    var offset: SIMD2<Int16>
    var size: SIMD2<UInt16>
    var atlas: SIMD2<UInt16>
    var color: SIMD4<UInt8>
    var texture: UInt8
    var flags: UInt8
    var padding: UInt16 = 0
}

/// A Command-hovered link: the columns underlined on each viewport row it covers.
struct TerminalLink: Equatable {
    var rows: [Int: ClosedRange<Int>]
}

/// A finished command beside the viewport: the rows from its prompt to its last output line, and
/// its exit code.
struct TerminalCommandMark: Equatable {
    var rows: ClosedRange<Int>
    var exitCode: Int32
}

/// Builds per-cell backgrounds and glyph instances, rebuilding only dirty rows and the rows the cursor left or entered. Rows sit one
/// slot down: slots 0 and `rows + 1` hold the overscan rows drawn while scrolling by less than a row.
final class TerminalFrameBuilder {
    let font: TerminalFont
    let atlas: GlyphAtlas
    var selectionBackground = VTColor(r: 0x3A, g: 0x5F, b: 0x9E)
    /// Background of search matches other than the current one, which is the selection.
    var matchBackground = VTColor(r: 0x6B, g: 0x5B, b: 0x1F)
    var link: TerminalLink?
    var markColors = (success: VTColor(r: 0x3F, g: 0xB9, b: 0x50), failure: VTColor(r: 0xE5, g: 0x48, b: 0x4D)) {
        didSet { appliedMarks = [] }
    }

    private(set) var cols = 0
    private(set) var rows = 0
    /// RGBA per cell, `rows + 2` rows of slots; zero alpha means the default background.
    private(set) var backgrounds: [UInt32] = []
    var instanceCount: Int { rowInstances.reduce(0) { $0 + $1.count } + markInstances.count }
    private(set) var defaultBackground = VTColor(r: 0, g: 0, b: 0)
    private(set) var defaultForeground = VTColor(r: 255, g: 255, b: 255)
    private(set) var cursorColor: VTColor?
    private(set) var cursor: VTCursor?

    let shaper: RunShaper
    private var rowInstances: [[GlyphInstance]] = []
    private var markInstances: [GlyphInstance] = []
    private var appliedMarks: [TerminalCommandMark] = []
    private var appliedHoveredRow: Int?
    private var atlasGeneration = 0
    private var appliedSelectionBackground: VTColor?
    private var appliedMatchBackground: VTColor?
    private var appliedLink: TerminalLink?
    private var highlights: [Int: [ClosedRange<Int>]] = [:]
    private var appliedHighlights: [(row: Int, columns: ClosedRange<Int>)] = []
    private var runKey: [UInt32] = []
    private var runColors: [SIMD4<UInt8>] = []
    /// Per run cell: whether a wide character starts there.
    private var runWide: [Bool] = []
    private var runStart = 0
    private var runFace = 0

    init(font: TerminalFont, atlas: GlyphAtlas) {
        self.font = font
        self.atlas = atlas
        shaper = RunShaper(font: font)
    }

    /// Returns false when the frame is identical to the previous one. `highlights` are the search
    /// matches on screen; nil keeps the previous ones.
    func update(from state: VTRenderState, highlights newHighlights: [(row: Int, columns: ClosedRange<Int>)]? = nil) -> Bool {
        var highlightRows: Set<Int> = []
        if let newHighlights, !newHighlights.elementsEqual(appliedHighlights, by: { $0.row == $1.row && $0.columns == $1.columns }) {
            appliedHighlights = newHighlights
            let grouped = Dictionary(grouping: newHighlights, by: \.row).mapValues { $0.map(\.columns) }
            highlightRows = Set(grouped.keys).union(highlights.keys).filter { grouped[$0] != highlights[$0] }
            highlights = grouped
        }
        if link != appliedLink {
            highlightRows.formUnion([appliedLink, link].compactMap { $0 }.flatMap(\.rows.keys))
            appliedLink = link
        }
        let (cols, rows) = state.size
        let newCursor = state.cursor
        let resized = cols != self.cols || rows != self.rows
        let dirty = state.dirty
        let colors = state.colors
        let recolored = colors.background != defaultBackground || colors.foreground != defaultForeground
            || colors.cursor != cursorColor || selectionBackground != appliedSelectionBackground
            || matchBackground != appliedMatchBackground
        guard dirty != .clean || newCursor != cursor || resized || recolored || !highlightRows.isEmpty
            || atlas.generation != atlasGeneration else { return false }
        if resized {
            self.cols = cols
            self.rows = rows
            backgrounds = Array(repeating: 0, count: cols * (rows + 2))
            rowInstances = Array(repeating: [], count: rows + 2)
        }
        (defaultBackground, defaultForeground, cursorColor) = colors
        appliedSelectionBackground = selectionBackground
        appliedMatchBackground = matchBackground
        let previousCursor = cursor
        cursor = newCursor
        // Runs break at the cursor, so the rows it left and entered are reshaped as well.
        let cursorMoved = previousCursor?.x != newCursor?.x || previousCursor?.y != newCursor?.y || previousCursor?.style != newCursor?.style
        let (leftRow, enteredRow) = cursorMoved ? (previousCursor?.y, newCursor?.y) : (nil, nil)

        // A full atlas is refilled while building; positions cached in earlier rows are then stale.
        for attempt in 0..<2 {
            let everything = dirty == .full || resized || recolored || atlas.generation != atlasGeneration || attempt > 0
            atlasGeneration = atlas.generation
            state.forEachRow { y, rowDirty, selection in
                guard (-1...rows).contains(y), everything || rowDirty || y == leftRow || y == enteredRow || highlightRows.contains(y) else { return }
                buildRow(y, selection: selection, state: state)
            }
            if atlas.generation == atlasGeneration { break }
        }
        // An overscan row that no longer exists (top of history, or following the bottom) is empty.
        let overscan = state.overscan
        if overscan.above == 0 { clearSlot(0) }
        if overscan.below == 0 { clearSlot(rows + 1) }
        return true
    }

    /// A bar in the left padding beside each command, `x` pixels from the grid (negative) and
    /// `width` wide; the one covering `hoveredRow` doubles and turns opaque. Returns false when the
    /// bars are the ones already drawn.
    func updateCommandMarks(_ marks: [TerminalCommandMark], hoveredRow: Int?, x: Int, width: Int) -> Bool {
        guard marks != appliedMarks || hoveredRow != appliedHoveredRow || markInstances.isEmpty != marks.isEmpty else { return false }
        appliedMarks = marks
        appliedHoveredRow = hoveredRow
        markInstances = marks.map { mark in
            let color = mark.exitCode == 0 ? markColors.success : markColors.failure
            let hovered = hoveredRow.map(mark.rows.contains) ?? false
            // Success is the expected outcome: faint until hovered, so failures stand out.
            let alpha: UInt8 = hovered ? 255 : mark.exitCode == 0 ? 50 : 230
            // Rows sit one slot down; two pixels short at the bottom keep neighbouring commands apart.
            return solid(column: 0, slot: mark.rows.lowerBound + 1, x: hovered ? x - width / 2 : x, top: 1,
                         width: hovered ? width * 2 : width, height: max(1, mark.rows.count * font.cellHeight - 3),
                         color: SIMD4(color.r, color.g, color.b, alpha))
        }
        return true
    }

    /// Copies every row's instances back to back; returns how many were written.
    func copyInstances(to destination: UnsafeMutablePointer<GlyphInstance>, capacity: Int) -> Int {
        var written = 0
        func copy(_ row: [GlyphInstance]) {
            guard written + row.count <= capacity else { return }
            row.withUnsafeBufferPointer { source in
                (destination + written).update(from: source.baseAddress!, count: source.count)
            }
            written += row.count
        }
        rowInstances.forEach(copy)
        copy(markInstances)
        return written
    }

    private func clearSlot(_ slot: Int) {
        guard !rowInstances[slot].isEmpty || backgrounds[slot * cols..<(slot + 1) * cols].contains(where: { $0 != 0 }) else { return }
        rowInstances[slot].removeAll(keepingCapacity: true)
        for index in slot * cols..<(slot + 1) * cols { backgrounds[index] = 0 }
    }

    private func buildRow(_ y: Int, selection: ClosedRange<Int>?, state: VTRenderState) {
        let slot = y + 1
        // Taken out of `rowInstances` so the buffer is uniquely referenced and cleared in place.
        var instances = rowInstances[slot]
        rowInstances[slot] = []
        instances.removeAll(keepingCapacity: true)
        runKey.removeAll(keepingCapacity: true)
        let blockCursorX = cursor.flatMap { $0.y == y && $0.style == .block ? $0.x : nil }
        let rowHighlights = highlights[y] ?? []

        state.forEachCell { x, cell in
            guard x < cols else { return }
            let selected = selection?.contains(x) ?? false
            var foreground = cell.foreground ?? defaultForeground
            var background = cell.background
            if cell.inverse {
                (foreground, background) = (background ?? defaultBackground, foreground)
            }
            if selected {
                background = selectionBackground
            } else if rowHighlights.contains(where: { $0.contains(x) }) {
                background = matchBackground
            }
            backgrounds[slot * cols + x] = background.map { UInt32($0.r) | UInt32($0.g) << 8 | UInt32($0.b) << 16 | 0xFF00_0000 } ?? 0

            let color = SIMD4<UInt8>(foreground.r, foreground.g, foreground.b, cell.faint ? 128 : 255)
            // The wide character before a spacer already drew its glyph and decorations across both cells.
            guard cell.width != .spacer else { return }
            let span = cell.width == .wide ? 2 : 1
            if cell.underline || cell.strikethrough {
                let lineTop = cell.underline
                    ? font.baseline + font.underlineOffset - font.lineThickness / 2
                    : font.baseline - font.cellHeight / 4
                instances.append(solid(column: x, slot: slot, top: lineTop, width: font.cellWidth * span, height: font.lineThickness, color: color))
            }

            let codepoints = cell.codepoints
            let face = (cell.bold ? 1 : 0) | (cell.italic ? 2 : 0)
            let isCursorCell = x == blockCursorX
            // A space draws nothing and no ligature crosses one: ending the run there keeps shaping
            // per word, so a ticking counter reshapes itself, not its whole line.
            guard !codepoints.isEmpty, codepoints.count > 1 || codepoints[0] != 0x20, !cell.invisible else {
                flushRun(slot: slot, into: &instances, cursorX: blockCursorX)
                return
            }
            if codepoints.count == 1, GlyphAtlas.isSprite(codepoints[0]) {
                flushRun(slot: slot, into: &instances, cursorX: blockCursorX)
                if let sprite = atlas.sprite(
                    codepoints[0], cellWidth: font.cellWidth, cellHeight: font.cellHeight,
                    baseline: font.baseline, thickness: font.lineThickness
                ) {
                    instances.append(instance(for: sprite, x: x, slot: slot, penX: 0, penY: 0, color: color, cursor: isCursorCell))
                }
                return
            }
            // The cursor cell is shaped on its own so it never lands inside a ligature.
            if !runKey.isEmpty, face != runFace || isCursorCell || runStart == blockCursorX {
                flushRun(slot: slot, into: &instances, cursorX: blockCursorX)
            }
            if runKey.isEmpty {
                runKey.append(UInt32(face))
                runFace = face
                runStart = x
                runColors.removeAll(keepingCapacity: true)
                runWide.removeAll(keepingCapacity: true)
            }
            runKey.append(contentsOf: codepoints)
            runKey.append(span == 2 ? RunShaper.wideCellEnd : RunShaper.narrowCellEnd)
            runColors.append(color)
            runWide.append(span == 2)
            if span == 2 {
                runColors.append(color)
                runWide.append(false)
            }
        }
        flushRun(slot: slot, into: &instances, cursorX: blockCursorX)
        if let columns = link?.rows[y], columns.upperBound < cols {
            let color = SIMD4<UInt8>(defaultForeground.r, defaultForeground.g, defaultForeground.b, 255)
            instances.append(solid(column: columns.lowerBound, slot: slot, top: font.baseline + font.underlineOffset - font.lineThickness / 2,
                                   width: font.cellWidth * columns.count, height: font.lineThickness, color: color))
        }
        rowInstances[slot] = instances
    }

    private func flushRun(slot: Int, into instances: inout [GlyphInstance], cursorX: Int?) {
        guard !runKey.isEmpty else { return }
        for shaped in shaper.shape(runKey) {
            let runFont = shaper.fonts[shaped.font]
            guard shaped.cell < runColors.count,
                  let glyph = atlas.glyph(shaped.glyph, font: runFont, fontIndex: shaped.font) else { continue }
            let x = runStart + shaped.cell
            // Fallback fonts rarely fill exactly two cells: wide characters sit centered in theirs.
            let penX = runWide[shaped.cell] && shaped.x == 0
                ? (2 * font.cellWidth - Int(glyph.width)) / 2 - Int(glyph.left)
                : Int(shaped.x.rounded())
            instances.append(instance(
                for: glyph, x: x, slot: slot, penX: penX, penY: Int(shaped.y.rounded()),
                color: runColors[shaped.cell], cursor: x == cursorX
            ))
        }
        runKey.removeAll(keepingCapacity: true)
    }

    /// A filled rectangle: an underline, a strikethrough, a link underline or a command bar.
    private func solid(column: Int, slot: Int, x: Int = 0, top: Int, width: Int, height: Int, color: SIMD4<UInt8>) -> GlyphInstance {
        GlyphInstance(grid: SIMD2(UInt16(column), UInt16(slot)), offset: SIMD2(Int16(x), Int16(top)),
                      size: SIMD2(UInt16(width), UInt16(height)), atlas: .zero, color: color, texture: 0, flags: GlyphInstance.solid)
    }

    private func instance(for glyph: AtlasGlyph, x: Int, slot: Int, penX: Int, penY: Int, color: SIMD4<UInt8>, cursor: Bool) -> GlyphInstance {
        GlyphInstance(
            grid: SIMD2(UInt16(x), UInt16(slot)),
            offset: SIMD2(Int16(penX) + glyph.left, Int16(font.baseline - penY) - glyph.top),
            size: SIMD2(glyph.width, glyph.height),
            atlas: SIMD2(glyph.x, glyph.y),
            color: color,
            texture: glyph.isColor ? 1 : 0,
            flags: cursor ? GlyphInstance.cursorGlyph : 0
        )
    }
}
