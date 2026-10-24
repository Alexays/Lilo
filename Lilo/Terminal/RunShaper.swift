import CoreText
import Foundation

/// One shaped glyph, placed relative to the left edge of the cell its cluster starts in.
struct ShapedGlyph {
    var font: Int
    var glyph: CGGlyph
    var cell: Int
    var x: Float
    var y: Float
}

/// Shapes runs of same-face text with CoreText (ligatures, font fallback) and snaps every cluster
/// to its grid cell. Results are cached by content, so unchanged text never reaches CoreText again.
final class RunShaper {
    /// Ends a cell's codepoints inside a run key; the value says how many columns the cell spans.
    static let narrowCellEnd: UInt32 = 0
    static let wideCellEnd: UInt32 = 1
    private static let cacheLimit = 8192

    private(set) var fonts: [CTFont] = []
    /// Rebuilt on demand: a terminal hidden for a while drops it.
    var cache: [[UInt32]: [ShapedGlyph]] = [:]
    private let faces: [CTFont]

    init(font: TerminalFont) {
        faces = font.faces
    }

    /// `key` is the face index followed by each cell's codepoints and a cell terminator.
    func shape(_ key: [UInt32]) -> [ShapedGlyph] {
        if let cached = cache[key] { return cached }
        var text = String.UnicodeScalarView()
        var cellForUTF16: [Int] = []
        var cell = 0
        for value in key.dropFirst() {
            if value == Self.narrowCellEnd || value == Self.wideCellEnd {
                cell += value == Self.wideCellEnd ? 2 : 1
                continue
            }
            guard let scalar = Unicode.Scalar(value) else { continue }
            text.append(scalar)
            cellForUTF16.append(contentsOf: repeatElement(cell, count: scalar.utf16.count))
        }

        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): faces[Int(key[0])]]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(text), attributes: attributes))
        var shaped: [ShapedGlyph] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
            let fontIndex = index(of: runFont)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            // Positions are relative to each cluster's first glyph, so proportional fallback fonts
            // (CJK, emoji) cannot drift off the grid.
            var clusterCell = -1
            var clusterX: CGFloat = 0
            for index in 0..<count {
                let cell = cellForUTF16[indices[index]]
                if cell != clusterCell {
                    clusterCell = cell
                    clusterX = positions[index].x
                }
                shaped.append(ShapedGlyph(
                    font: fontIndex, glyph: glyphs[index], cell: cell,
                    x: Float(positions[index].x - clusterX), y: Float(positions[index].y)
                ))
            }
        }
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = shaped
        return shaped
    }

    /// A linear scan: a terminal uses a handful of fonts, its face and a few fallbacks.
    private func index(of font: CTFont) -> Int {
        if let index = fonts.firstIndex(where: { CFEqual($0, font) }) { return index }
        fonts.append(font)
        return fonts.count - 1
    }
}
