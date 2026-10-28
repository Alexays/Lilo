import AppKit
import CoreImage
import ScreenCaptureKit
import XCTest

/// Captures only this test process's window; never enumerates the person's windows.
final class ReleaseWindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let directory: URL
    private let queue = DispatchQueue(label: "lilo.release-recording")
    private let context = CIContext()
    private var stream: SCStream?
    private var firstTime: CMTime?
    private var frames: [[String: Any]] = []
    private var failure: Error?
    private var checkpoints: [[String: Any]] = []

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor
    func start(window: NSWindow) async throws {
        let content = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }, "The capture window must be visible")
        let configuration = SCStreamConfiguration()
        configuration.width = 1120
        configuration.height = 720
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let ready = await pollUntil(timeout: 5) { self.queue.sync { !self.frames.isEmpty || self.failure != nil } }
        guard ready else { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "ScreenCaptureKit produced no window frames"]) }
        if let failure = queue.sync(execute: { failure }) { throw failure }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, failure == nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              let pixels = sampleBuffer.imageBuffer else { return }
        do {
            guard frames.count < 450 else { throw CocoaError(.fileWriteOutOfSpace) }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if firstTime == nil { firstTime = timestamp }
            let atMs = Int((CMTimeGetSeconds(timestamp - firstTime!) * 1000).rounded())
            let name = String(format: "frame-%04d.png", frames.count)
            try context.writePNGRepresentation(of: CIImage(cvPixelBuffer: pixels), to: directory.appendingPathComponent(name), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            frames.append(["file": name, "atMs": atMs])
        } catch { failure = error }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.failure = error } }

    private var elapsedMs: Int {
        queue.sync { firstTime.map { Int((CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()) - $0) * 1000).rounded()) } ?? 0 }
    }

    @MainActor
    func checkpoint(_ name: String, passed: Bool) throws {
        guard passed else { throw CocoaError(.validationMissingMandatoryProperty, userInfo: [NSLocalizedDescriptionKey: "Native checkpoint failed: \(name)"]) }
        checkpoints.append(["name": name, "atMs": elapsedMs, "passed": passed])
    }

    @MainActor
    func finish(scenario: String) async throws {
        guard let stream else { throw CocoaError(.fileReadUnknown) }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: "macOS locked during native capture; release media remains blocked"])
        }
        let durationMs = elapsedMs
        try await stream.stopCapture()
        self.stream = nil
        let (frames, failure) = queue.sync { (self.frames, self.failure) }
        if let failure { throw failure }
        let manifest: [String: Any] = [
            "scenario": scenario, "source": "native", "captureTool": "ScreenCaptureKit.currentProcess",
            "inputDigest": try XCTUnwrap(ProcessInfo.processInfo.environment["LILO_RELEASE_CAPTURE_INPUT_DIGEST"]),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "width": 1120, "height": 720, "durationMs": durationMs, "frames": frames, "checkpoints": checkpoints
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    @MainActor
    func cancel() async { try? await stream?.stopCapture(); stream = nil }
}
