import CoreMedia
import ScreenCaptureKit

/// A ScreenCaptureKit stream of a display or window the user picked, feeding the tab-share ferry.
/// ScreenCaptureKit scales each frame to the session's size and only delivers a frame when the
/// content changed, so a still screen costs nothing past the ferry's own tick.
@MainActor
final class ScreenCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let width: Int
    let height: Int
    /// The getDisplayMedia `displaySurface` of the pick.
    let surface: String
    private(set) var latestFrame: CVPixelBuffer?
    private(set) var frameCount = 0
    /// The stream stopped on its own: the user ended it from the system menu, or the window closed.
    var onStop: (() -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.lilo.screen-capture")

    private struct FrameBox: @unchecked Sendable { let buffer: CVPixelBuffer }

    init(filter: SCContentFilter) {
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size
        let pixels = size.width > 0 && size.height > 0 ? NSSize(width: size.width * scale, height: size.height * scale) : NSSize(width: 1280, height: 720)
        let fit = min(1, TabShareSessionController.maxFrameWidth / pixels.width)
        // H.264 needs even dimensions.
        width = Int(pixels.width * fit) & ~1
        height = Int(pixels.height * fit) & ~1
        surface = filter.style == .window ? "window" : "monitor"
        super.init()
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(TabShareSessionController.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    func start() async throws {
        guard let stream else { return }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        latestFrame = nil
        stream.stopCapture { _ in }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[.status] as? Int).flatMap(SCFrameStatus.init) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        let frame = FrameBox(buffer: buffer)
        Task { @MainActor in
            guard self.stream != nil else { return }
            self.latestFrame = frame.buffer
            self.frameCount += 1
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard self.stream != nil else { return }
            self.stream = nil
            self.latestFrame = nil
            self.onStop?()
        }
    }
}

/// The system content-sharing picker, for a pick made ahead of any page (`chrome.desktopCapture`).
/// The pick is the user's consent, so no Screen Recording permission is needed.
@MainActor
final class ScreenContentPicker: NSObject, SCContentSharingPickerObserver {
    /// SCContentFilter is immutable once the picker made it, but not Sendable-annotated.
    private struct Pick: @unchecked Sendable { let filter: SCContentFilter? }
    private var continuation: CheckedContinuation<Pick, Never>?
    private var previousConfiguration: SCContentSharingPickerConfiguration?
    private var wasActive = false

    /// The display or window the user picked, nil when cancelled; cancelling the task resolves nil.
    func pick(allowing modes: SCContentSharingPickerMode) async -> SCContentFilter? {
        guard continuation == nil else { return nil }
        let picker = SCContentSharingPicker.shared
        previousConfiguration = picker.defaultConfiguration
        wasActive = picker.isActive
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = modes
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                picker.present()
            }
        } onCancel: {
            Task { @MainActor in self.finish(Pick(filter: nil)) }
        }.filter
    }

    private func finish(_ pick: Pick) {
        guard let continuation else { return }
        self.continuation = nil
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        if let previousConfiguration { picker.defaultConfiguration = previousConfiguration }
        picker.isActive = wasActive
        continuation.resume(returning: pick)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(Pick(filter: nil)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let pick = Pick(filter: filter)
        Task { @MainActor in self.finish(pick) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.finish(Pick(filter: nil)) }
    }
}
