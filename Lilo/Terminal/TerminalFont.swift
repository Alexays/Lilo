import AppKit
import CoreText

/// The terminal font's four faces at device-pixel size, and the cell grid they define.
final class TerminalFont {
    /// Regular, bold, italic, bold italic: bit 0 is bold, bit 1 italic.
    let faces: [CTFont]
    let cellWidth: Int
    let cellHeight: Int
    /// Distance from the top of a cell to the baseline.
    let baseline: Int
    let underlineOffset: Int
    let lineThickness: Int

    /// `family` is a font family name (nil for the system monospaced font).
    init(family: String?, pointSize: CGFloat, scale: CGFloat) {
        let pixelSize = pointSize * scale
        var regular = NSFont.monospacedSystemFont(ofSize: pixelSize, weight: .regular) as CTFont
        if let family, !family.isEmpty {
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, pixelSize, nil)
            // A family that is not installed comes back as a proportional fallback: keep the system font.
            if CTFontCopyFamilyName(font) as String == family { regular = font }
        }
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(regular, pixelSize, nil, traits, traits) ?? regular
        }
        faces = [regular, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]

        var character: UniChar = 0x4D // "M"
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(regular, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        cellWidth = max(1, Int(advance.width.rounded(.up)))
        cellHeight = max(1, Int((ascent + descent + leading).rounded(.up)))
        // Leading is split above and below so the text sits centered in its cell.
        baseline = Int((ascent + leading / 2).rounded())
        underlineOffset = max(1, Int((-CTFontGetUnderlinePosition(regular)).rounded()))
        lineThickness = max(1, Int(CTFontGetUnderlineThickness(regular).rounded()))
    }
}
