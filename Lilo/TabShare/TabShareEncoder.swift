import CoreGraphics
import CoreMedia
import VideoToolbox

/// Hardware H.264 encoder for the tab-share ferry. The page decodes with WebCodecs, so frames cross
/// the process boundary at a fraction of JPEG's size and decode off its main thread.
/// Not thread-safe: the session controller keeps a single encode in flight.
final class TabShareEncoder: @unchecked Sendable {
    struct Chunk {
        /// AVCC (length-prefixed NAL units), as WebCodecs expects once given a description.
        let data: Data
        /// Keyframes only: the WebCodecs codec string and the avcC record to configure with.
        let config: (codec: String, description: Data)?
    }

    enum Result {
        case chunk(Chunk)
        case unchanged
        case failed
    }

    let width: Int
    let height: Int
    private let session: VTCompressionSession?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var lastPixels: CFData?
    private var frameIndex: Int64 = 0

    /// The output handler runs on a VideoToolbox thread; `CompleteFrames` returns only after it did.
    private final class OutputBox: @unchecked Sendable { var sample: CMSampleBuffer? }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        var session: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        if let session {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            // Low-latency rate control only takes the constrained profiles.
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
            // Local IPC, not a network: spend bits until text is visually lossless.
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: width * height * 8 as CFNumber)
        }
        self.session = session
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    /// Encodes `image` fitted into the fixed frame. Identical pixels are skipped unless a keyframe
    /// is forced: every encoded frame joins the decoder's reference chain, so none may be dropped.
    func encode(_ image: CGImage, forceKey: Bool) -> Result {
        guard let session, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return .failed }
        let pixels = image.dataProvider?.data
        if !forceKey, let pixels, let lastPixels, CFEqual(pixels, lastPixels) { return .unchanged }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { return .failed }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        if let context {
            // A resized tab keeps its aspect ratio inside the session's fixed frame.
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            let scale = min(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
            let fitted = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(frame)
            context.draw(image, in: CGRect(origin: CGPoint(x: (frame.width - fitted.width) / 2, y: (frame.height - fitted.height) / 2), size: fitted))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard context != nil else { return .failed }
        let result = encode(pixelBuffer, forceKey: forceKey)
        // Recorded only once encoded: a frame that failed is tried again, not skipped as unchanged.
        if case .chunk = result { lastPixels = pixels }
        return result
    }

    /// Encodes a frame already at the session's size, as ScreenCaptureKit delivers them.
    func encode(_ pixelBuffer: CVPixelBuffer, forceKey: Bool) -> Result {
        guard let session else { return .failed }
        let box = OutputBox()
        let pts = CMTime(value: frameIndex, timescale: 30)
        frameIndex += 1
        let properties = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            if status == noErr { box.sample = sample }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        guard status == noErr, let sample = box.sample, let data = try? sample.dataBuffer?.dataBytes() else { return .failed }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        guard attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true else {
            return .chunk(Chunk(data: data, config: nil))
        }
        guard let format = sample.formatDescription,
              let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let avcC = atoms["avcC"] as? Data, avcC.count > 3 else { return .failed }
        // avc1.PPCCLL: profile, constraint flags and level, straight from the avcC header.
        let codec = "avc1." + avcC[avcC.startIndex + 1...avcC.startIndex + 3].map { String(format: "%02X", $0) }.joined()
        return .chunk(Chunk(data: data, config: (codec, avcC)))
    }
}
