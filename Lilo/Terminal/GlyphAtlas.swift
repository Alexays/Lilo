import CoreText
import Metal

/// Where a rasterized glyph lives in the atlas, and how it sits relative to its pen position.
struct AtlasGlyph {
    var x: UInt16
    var y: UInt16
    var width: UInt16
    var height: UInt16
    /// Offset of the bitmap's left edge from the pen, in pixels.
    var left: Int16
    /// Offset of the bitmap's top edge above the baseline, in pixels.
    var top: Int16
    var isColor: Bool
}

/// Glyph bitmaps for one font at one scale: an R8 texture for text, a BGRA one for color emoji,
/// both packed in shelves. A full atlas is cleared and refilled; `generation` tells callers that
/// every cached position is stale.
final class GlyphAtlas {
    private struct Key: Hashable {
        var font: Int
        var glyph: CGGlyph
    }

    private struct Shelf {
        var x = 0
        var y = 0
        var height = 0
    }

    let grayTexture: MTLTexture
    let colorTexture: MTLTexture
    /// Runs before a full atlas is overwritten, while frames still on the GPU may sample it.
    var willReset: (() -> Void)?
    private(set) var generation = 0
    private var entries: [Key: AtlasGlyph?] = [:]
    private var grayShelf = Shelf()
    private var colorShelf = Shelf()
    private var scratch: [UInt8] = []

    init(device: MTLDevice) {
        func texture(_ format: MTLPixelFormat, _ size: Int) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            return device.makeTexture(descriptor: descriptor)!
        }
        grayTexture = texture(.r8Unorm, 1024)
        colorTexture = texture(.bgra8Unorm, 512)
    }

    /// Returns nil for glyphs with no ink (spaces).
    func glyph(_ glyph: CGGlyph, font: CTFont, fontIndex: Int) -> AtlasGlyph? {
        let key = Key(font: fontIndex, glyph: glyph)
        if let cached = entries[key] { return cached }
        var glyph = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        guard bounds.width > 0, bounds.height > 0 else {
            entries[key] = .some(nil)
            return nil
        }
        let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        // One pixel of padding on every side keeps antialiased edges from bleeding into neighbors.
        let left = Int(bounds.minX.rounded(.down)) - 1
        let bottom = Int(bounds.minY.rounded(.down)) - 1
        let width = Int(bounds.maxX.rounded(.up)) - left + 1
        let height = Int(bounds.maxY.rounded(.up)) - bottom + 1
        let entry = rasterize(width: width, height: height, color: isColor, left: left, top: bottom + height) { context in
            var origin = CGPoint(x: -CGFloat(left), y: -CGFloat(bottom))
            CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
        }
        entries[key] = .some(entry)
        return entry
    }

    /// Box-drawing and block characters drawn to fill the cell exactly, so lines join across cells.
    func sprite(_ codepoint: UInt32, cellWidth: Int, cellHeight: Int, baseline: Int, thickness: Int) -> AtlasGlyph? {
        // Font -1 keys sprites by codepoint, apart from the glyphs of every real face.
        let key = Key(font: -1, glyph: CGGlyph(truncatingIfNeeded: codepoint))
        if let cached = entries[key] { return cached }
        let entry = rasterize(width: cellWidth, height: cellHeight, color: false, left: 0, top: baseline) { context in
            Self.drawSprite(codepoint, in: context, width: CGFloat(cellWidth), height: CGFloat(cellHeight), thickness: CGFloat(thickness))
        }
        entries[key] = .some(entry)
        return entry
    }

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let gray = CGColorSpaceCreateDeviceGray()

    static func isSprite(_ codepoint: UInt32) -> Bool {
        lineWeights(codepoint) != nil || (0x2580...0x259F).contains(codepoint) || (0x256D...0x2570).contains(codepoint)
    }

    private func rasterize(width: Int, height: Int, color: Bool, left: Int, top: Int, draw: (CGContext) -> Void) -> AtlasGlyph? {
        let texture = color ? colorTexture : grayTexture
        guard width <= texture.width, height <= texture.height else { return nil }
        guard let origin = allocate(width: width, height: height, color: color) ?? {
            reset()
            return allocate(width: width, height: height, color: color)
        }() else { return nil }
        let bytesPerRow = width * (color ? 4 : 1)
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: repeatElement(0, count: bytesPerRow * height))
        scratch.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: color ? Self.srgb : Self.gray,
                bitmapInfo: color
                    ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    : CGImageAlphaInfo.none.rawValue
            )!
            context.setAllowsAntialiasing(true)
            context.setShouldSmoothFonts(false)
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            draw(context)
            texture.replace(
                region: MTLRegionMake2D(origin.x, origin.y, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: bytesPerRow
            )
        }
        return AtlasGlyph(
            x: UInt16(origin.x), y: UInt16(origin.y), width: UInt16(width), height: UInt16(height),
            left: Int16(left), top: Int16(top), isColor: color
        )
    }

    private func allocate(width: Int, height: Int, color: Bool) -> (x: Int, y: Int)? {
        let size = color ? colorTexture.width : grayTexture.width
        var shelf = color ? colorShelf : grayShelf
        if shelf.x + width > size {
            shelf.y += shelf.height
            shelf.x = 0
            shelf.height = 0
        }
        guard shelf.y + height <= size else { return nil }
        let origin = (shelf.x, shelf.y)
        shelf.x += width
        shelf.height = max(shelf.height, height)
        if color { colorShelf = shelf } else { grayShelf = shelf }
        return origin
    }

    private func reset() {
        willReset?()
        entries.removeAll(keepingCapacity: true)
        grayShelf = Shelf()
        colorShelf = Shelf()
        generation += 1
    }

    /// Weights of the four arms (up, right, down, left): 0 none, 1 light, 2 heavy.
    private static func lineWeights(_ codepoint: UInt32) -> (UInt8, UInt8, UInt8, UInt8)? {
        switch codepoint {
        case 0x2500: (0, 1, 0, 1)
        case 0x2501: (0, 2, 0, 2)
        case 0x2502: (1, 0, 1, 0)
        case 0x2503: (2, 0, 2, 0)
        case 0x250C: (0, 1, 1, 0)
        case 0x250F: (0, 2, 2, 0)
        case 0x2510: (0, 0, 1, 1)
        case 0x2513: (0, 0, 2, 2)
        case 0x2514: (1, 1, 0, 0)
        case 0x2517: (2, 2, 0, 0)
        case 0x2518: (1, 0, 0, 1)
        case 0x251B: (2, 0, 0, 2)
        case 0x251C: (1, 1, 1, 0)
        case 0x2523: (2, 2, 2, 0)
        case 0x2524: (1, 0, 1, 1)
        case 0x252B: (2, 0, 2, 2)
        case 0x252C: (0, 1, 1, 1)
        case 0x2533: (0, 2, 2, 2)
        case 0x2534: (1, 1, 0, 1)
        case 0x253B: (2, 2, 0, 2)
        case 0x253C: (1, 1, 1, 1)
        case 0x254B: (2, 2, 2, 2)
        case 0x2574: (0, 0, 0, 1)
        case 0x2575: (1, 0, 0, 0)
        case 0x2576: (0, 1, 0, 0)
        case 0x2577: (0, 0, 1, 0)
        default: nil
        }
    }

    private static func drawSprite(_ codepoint: UInt32, in context: CGContext, width: CGFloat, height: CGFloat, thickness: CGFloat) {
        // CoreGraphics puts the origin at the bottom left; rows of the cell are measured from the top.
        let midX = (width / 2).rounded(.down)
        let midY = (height / 2).rounded(.down)
        if case let (up, right, down, left)? = lineWeights(codepoint) {
            func arm(_ weight: UInt8, _ rect: (CGFloat) -> CGRect) {
                guard weight > 0 else { return }
                context.fill(rect(weight == 2 ? thickness * 2 : thickness))
            }
            arm(up) { t in CGRect(x: midX - (t / 2).rounded(.down), y: midY - (t / 2).rounded(.down), width: t, height: height - midY + (t / 2).rounded(.down)) }
            arm(down) { t in CGRect(x: midX - (t / 2).rounded(.down), y: 0, width: t, height: midY + t - (t / 2).rounded(.down)) }
            arm(left) { t in CGRect(x: 0, y: midY - (t / 2).rounded(.down), width: midX + t - (t / 2).rounded(.down), height: t) }
            arm(right) { t in CGRect(x: midX - (t / 2).rounded(.down), y: midY - (t / 2).rounded(.down), width: width - midX + (t / 2).rounded(.down), height: t) }
            return
        }
        if (0x256D...0x2570).contains(codepoint) {
            // Rounded corners: ╭ ╮ ╯ ╰, an arc between the two arms that meet at the center.
            let toRight = codepoint == 0x256D || codepoint == 0x2570
            let toDown = codepoint == 0x256D || codepoint == 0x256E
            let end1 = CGPoint(x: midX + thickness / 2, y: toDown ? 0 : height)
            let end2 = CGPoint(x: toRight ? width : 0, y: midY + thickness / 2)
            let center = CGPoint(x: midX + thickness / 2, y: midY + thickness / 2)
            context.setLineWidth(thickness)
            context.move(to: end1)
            context.addQuadCurve(to: end2, control: center)
            context.strokePath()
            return
        }
        switch codepoint {
        case 0x2580: context.fill(CGRect(x: 0, y: midY, width: width, height: height - midY))
        case 0x2581...0x2587:
            let eighths = CGFloat(codepoint - 0x2580)
            context.fill(CGRect(x: 0, y: 0, width: width, height: (height * eighths / 8).rounded()))
        case 0x2588: context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case 0x2589...0x258F:
            let eighths = CGFloat(0x2590 - codepoint)
            context.fill(CGRect(x: 0, y: 0, width: (width * eighths / 8).rounded(), height: height))
        case 0x2590: context.fill(CGRect(x: midX, y: 0, width: width - midX, height: height))
        case 0x2591...0x2593:
            context.setFillColor(gray: 1, alpha: CGFloat(codepoint - 0x2590) / 4)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case 0x2594: context.fill(CGRect(x: 0, y: height - (height / 8).rounded(), width: width, height: (height / 8).rounded()))
        case 0x2595: context.fill(CGRect(x: width - (width / 8).rounded(), y: 0, width: (width / 8).rounded(), height: height))
        default:
            // Quadrants U+2596...U+259F: bits are upper-left, upper-right, lower-left, lower-right.
            let quadrants: [UInt32: UInt8] = [
                0x2596: 0b0010, 0x2597: 0b0001, 0x2598: 0b1000, 0x2599: 0b1011, 0x259A: 0b1001,
                0x259B: 0b1110, 0x259C: 0b1101, 0x259D: 0b0100, 0x259E: 0b0110, 0x259F: 0b0111
            ]
            guard let bits = quadrants[codepoint] else { return }
            if bits & 0b1000 != 0 { context.fill(CGRect(x: 0, y: midY, width: midX, height: height - midY)) }
            if bits & 0b0100 != 0 { context.fill(CGRect(x: midX, y: midY, width: width - midX, height: height - midY)) }
            if bits & 0b0010 != 0 { context.fill(CGRect(x: 0, y: 0, width: midX, height: midY)) }
            if bits & 0b0001 != 0 { context.fill(CGRect(x: midX, y: 0, width: width - midX, height: midY)) }
        }
    }
}
