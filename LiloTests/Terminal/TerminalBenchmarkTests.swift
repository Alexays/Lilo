import Metal
import XCTest
@testable import Lilo

/// Run with `make terminal-bench`; kept out of `make swift-test` because timings vary by machine.
@MainActor
final class TerminalBenchmarkTests: XCTestCase {
    func testPtyToTerminalThroughput() async throws {
        let size = 64 << 20
        let line = Array("the quick brown fox jumps over the lazy dog \u{1b}[32mgreen\u{1b}[0m 日本語\r\n".utf8)
        var data: [UInt8] = []
        data.reserveCapacity(size + line.count)
        while data.count < size { data += line }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-bench-\(UUID().uuidString).txt")
        try Data(data).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // The title change marks the point where every byte before it has been parsed.
        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 200, rows: 50,
            command: ["/bin/sh", "-c", "cat '\(file.path)'; printf '\\033]2;bench-done\\007'"]
        )
        defer { session.terminate() }

        let start = ContinuousClock.now
        try session.start()
        while session.status.title != "bench-done" { try await Task.sleep(for: .milliseconds(1)) }
        let seconds = (ContinuousClock.now - start) / .seconds(1)

        let throughput = Double(data.count) / 1e6 / seconds
        print("pty to terminal: \(Int(throughput)) MB/s")
        XCTAssertGreaterThan(throughput, 50)
    }

    func testParserYieldsToTheRendererDuringAFlood() async throws {
        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 200, rows: 50,
            command: ["/usr/bin/yes", "lilo terminal benchmark line"]
        )
        defer { session.terminate() }
        try session.start()
        try await Task.sleep(for: .milliseconds(200))

        var worst = Duration.zero
        for _ in 0..<200 {
            let before = ContinuousClock.now
            session.withLockedTerminal { _ in }
            worst = max(worst, ContinuousClock.now - before)
            try await Task.sleep(for: .milliseconds(8))
        }

        print("worst lock wait during a flood: \(worst)")
        XCTAssertLessThan(worst, .milliseconds(5))
    }

    /// Keystroke to pixels: the byte goes through the pty, its echo is parsed, and a frame is built
    /// and drawn on the GPU. Waits for the GPU, so it measures more than the display link adds.
    func testKeystrokeToFrameLatency() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(TerminalRenderer())
        let font = TerminalFont(family: nil, pointSize: 13, scale: 2)
        let builder = TerminalFrameBuilder(font: font, atlas: GlyphAtlas(device: device))
        let state = VTRenderState()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TerminalRenderer.pixelFormat, width: 100 * font.cellWidth, height: 30 * font.cellHeight, mipmapped: false
        )
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 100, rows: 30, command: ["/bin/cat"])
        let echoed = DispatchSemaphore(value: 0)
        session.onOutput = { echoed.signal() }
        defer { session.terminate() }
        try session.start()

        var samples: [Duration] = []
        // No newline: cat stays in its read, so every keystroke yields exactly one echo.
        for index in 0..<300 {
            let start = ContinuousClock.now
            session.write([UInt8(ascii: "a") + UInt8(index % 26)])
            echoed.wait()
            session.withLockedTerminal { state.beginUpdate(from: $0) }
            state.endUpdate()
            _ = builder.update(from: state)
            state.clean()
            var uniforms = TerminalUniforms()
            uniforms.viewport = SIMD2(Float(texture.width), Float(texture.height))
            uniforms.cellSize = SIMD2(Float(font.cellWidth), Float(font.cellHeight))
            uniforms.grid = SIMD2(UInt32(builder.cols), UInt32(builder.rows))
            renderer.render(builder, uniforms: uniforms, into: texture)
            renderer.waitUntilIdle()
            samples.append(ContinuousClock.now - start)
        }

        samples.sort()
        let median = samples[samples.count / 2]
        let p99 = samples[samples.count * 99 / 100]
        print("keystroke to frame: median \(median), p99 \(p99)")
        XCTAssertLessThan(p99, .milliseconds(8))
    }
}
