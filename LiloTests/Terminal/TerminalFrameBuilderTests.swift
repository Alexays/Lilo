import Metal
import XCTest
@testable import Lilo

final class TerminalFrameBuilderTests: XCTestCase {
    private let device = MTLCreateSystemDefaultDevice()!
    private let font = TerminalFont(family: nil, pointSize: 13, scale: 2)

    func testWideCharacterOccupiesTwoColumns() {
        let (builder, _) = build("a日b")

        let columns = Set(textInstances(builder).map { Int($0.grid.x) })

        XCTAssertEqual(columns, [0, 1, 3])
    }

    func testWordsKeepTheirCellsAcrossSpaces() {
        let (builder, _) = build("ab  c=>d")

        let columns = textInstances(builder).map { Int($0.grid.x) }

        XCTAssertEqual(columns, [0, 1, 4, 5, 6, 7])
    }

    func testBackgroundColorFillsTheCell() {
        let (builder, _) = build("\u{1b}[48;2;255;0;0m \u{1b}[0m ")

        // Row 0 of the viewport is slot 1: slot 0 holds the overscan row above it.
        XCTAssertEqual(builder.backgrounds[20], 0xFF00_00FF)
        XCTAssertEqual(builder.backgrounds[21], 0)
    }

    func testBlockCursorMarksTheGlyphUnderIt() {
        let (builder, _) = build("abc\u{1b}[2D")

        let marked = textInstances(builder).filter { $0.flags & GlyphInstance.cursorGlyph != 0 }

        XCTAssertEqual(marked.map { Int($0.grid.x) }, [1])
    }

    func testSwitchingToABlockCursorMarksTheGlyphUnderIt() {
        let terminal = VTTerminal(cols: 20, rows: 3, scrollbackBytes: 100_000)
        let state = VTRenderState()
        let builder = TerminalFrameBuilder(font: font, atlas: GlyphAtlas(device: device))
        func render(_ text: String) {
            Array(text.utf8).withUnsafeBytes { terminal.write($0) }
            state.beginUpdate(from: terminal)
            state.endUpdate()
            _ = builder.update(from: state)
            state.clean()
        }

        render("\u{1b}[6 qabc\u{1b}[2D")
        XCTAssertTrue(textInstances(builder).allSatisfy { $0.flags & GlyphInstance.cursorGlyph == 0 }, "A bar cursor inverts nothing")
        render("\u{1b}[2 q")

        XCTAssertEqual(textInstances(builder).filter { $0.flags & GlyphInstance.cursorGlyph != 0 }.map { Int($0.grid.x) }, [1])
    }

    func testSelectedCellsTakeTheSelectionBackground() {
        let terminal = VTTerminal(cols: 20, rows: 3, scrollbackBytes: 100_000)
        Array("hello world".utf8).withUnsafeBytes { terminal.write($0) }
        let gesture = VTSelectionGesture()
        let geometry = (columns: 20, cellWidth: 10, paddingX: 0, height: 60)
        gesture.handle(.press, cell: (0, 0), position: CGPoint(x: 2, y: 5), rectangle: false, geometry: geometry, terminal: terminal)
        gesture.handle(.drag, cell: (4, 0), position: CGPoint(x: 46, y: 5), rectangle: false, geometry: geometry, terminal: terminal)
        let state = VTRenderState()
        state.beginUpdate(from: terminal)
        state.endUpdate()
        let builder = TerminalFrameBuilder(font: font, atlas: GlyphAtlas(device: device))
        builder.selectionBackground = VTColor(r: 0x10, g: 0x20, b: 0x30)

        XCTAssertTrue(builder.update(from: state))

        XCTAssertEqual(Array(builder.backgrounds[20..<25]), Array(repeating: 0xFF30_2010, count: 5))
        XCTAssertEqual(builder.backgrounds[25], 0)
    }

    func testSearchMatchesTakeTheMatchBackgroundUntilCleared() {
        let (builder, state) = build("foo bar foo")
        builder.matchBackground = VTColor(r: 0x40, g: 0x50, b: 0x60)
        state.clean()

        XCTAssertTrue(builder.update(from: state, highlights: [(row: 0, columns: 8...10)]))
        XCTAssertEqual(Array(builder.backgrounds[28...30]), Array(repeating: 0xFF60_5040, count: 3))
        XCTAssertEqual(builder.backgrounds[27], 0)

        XCTAssertTrue(builder.update(from: state, highlights: []))
        XCTAssertEqual(builder.backgrounds[28], 0)
    }

    func testRowsJustOutsideTheViewportAreBuiltForSmoothScrolling() {
        let terminal = VTTerminal(cols: 20, rows: 3, scrollbackBytes: 100_000)
        Array((1...8).map { "line\($0)" }.joined(separator: "\r\n").utf8).withUnsafeBytes { terminal.write($0) }
        let state = VTRenderState()
        let builder = TerminalFrameBuilder(font: font, atlas: GlyphAtlas(device: device))
        func slots() -> Set<UInt16> {
            state.beginUpdate(from: terminal)
            state.endUpdate()
            _ = builder.update(from: state)
            state.clean()
            return Set(textInstances(builder).map(\.grid.y))
        }

        XCTAssertEqual(slots(), [0, 1, 2, 3], "Following the bottom: a row above, none below")
        terminal.scrollViewport(by: -2)
        XCTAssertEqual(slots(), [0, 1, 2, 3, 4], "Scrolled back: a row on each side")
    }

    func testBoxDrawingIsASpriteFillingTheCell() {
        let (builder, _) = build("─")

        let sprite = textInstances(builder).first

        XCTAssertEqual(sprite?.size, SIMD2(UInt16(font.cellWidth), UInt16(font.cellHeight)))
        XCTAssertEqual(sprite?.offset, SIMD2<Int16>(0, 0))
    }

    func testUnchangedScreenProducesNoNewFrame() {
        let (builder, state) = build("hello")
        state.clean()

        XCTAssertFalse(builder.update(from: state))
    }

    func testSolidBlockIsDrawnInItsForegroundColor() throws {
        let (builder, _) = build("\u{1b}[38;2;0;255;0m█")
        let pixel = try renderPixel(builder, padding: .zero, at: (font.cellWidth / 2, font.cellHeight / 2))
        XCTAssertEqual(pixel, [0, 255, 0, 255], "BGRA at the center of the first cell")
    }

    func testTopPaddingDoesNotShowTheRowAboveTheViewport() throws {
        // Three newlines on a three-row screen push the green row just above the viewport.
        let (builder, _) = build("\u{1b}[48;2;0;255;0m\u{1b}[38;2;0;255;0m█\u{1b}[0m\r\n\r\n\r\n")
        let padding = SIMD2<Float>(0, Float(font.cellHeight))
        let pixel = try renderPixel(builder, padding: padding, at: (font.cellWidth / 2, font.cellHeight / 2))
        XCTAssertEqual(pixel, [0, 0, 0, 255], "the padding keeps the background color")
    }

    /// BGRA of one pixel of a 200x100 frame drawn on a black background.
    private func renderPixel(_ builder: TerminalFrameBuilder, padding: SIMD2<Float>, at point: (x: Int, y: Int)) throws -> [UInt8] {
        let renderer = try XCTUnwrap(TerminalRenderer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TerminalRenderer.pixelFormat, width: 200, height: 100, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var uniforms = TerminalUniforms()
        uniforms.viewport = SIMD2(200, 100)
        uniforms.cellSize = SIMD2(Float(font.cellWidth), Float(font.cellHeight))
        uniforms.padding = padding
        uniforms.grid = SIMD2(UInt32(builder.cols), UInt32(builder.rows))
        uniforms.background = SIMD4(0, 0, 0, 1)

        renderer.render(builder, uniforms: uniforms, into: texture)
        // Command buffers on one queue complete in order, so this waits for the frame above.
        let fence = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        fence.commit()
        fence.waitUntilCompleted()

        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(point.x, point.y, 1, 1), mipmapLevel: 0)
        return pixel
    }

    private func build(_ text: String) -> (TerminalFrameBuilder, VTRenderState) {
        let terminal = VTTerminal(cols: 20, rows: 3, scrollbackBytes: 100_000)
        Array(text.utf8).withUnsafeBytes { terminal.write($0) }
        let state = VTRenderState()
        state.beginUpdate(from: terminal)
        state.endUpdate()
        let builder = TerminalFrameBuilder(font: font, atlas: GlyphAtlas(device: device))
        XCTAssertTrue(builder.update(from: state))
        return (builder, state)
    }

    private func textInstances(_ builder: TerminalFrameBuilder) -> [GlyphInstance] {
        let capacity = max(1, builder.instanceCount)
        let buffer = UnsafeMutablePointer<GlyphInstance>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let count = builder.copyInstances(to: buffer, capacity: capacity)
        return Array(UnsafeBufferPointer(start: buffer, count: count)).filter { $0.flags & GlyphInstance.solid == 0 }
    }
}
