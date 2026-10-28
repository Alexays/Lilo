import AppKit
import WebKit

/// Runs the tab-share frame ferry: snapshots a shared tab's engine (or takes a ScreenCaptureKit
/// stream's frames), H.264-encodes off the main thread, and stores the latest frame for the page shim
/// to pull over `lilo-capture://`. Sessions are independent: each has its own token and cadence.
@MainActor
final class TabShareSessionController {
    private final class Session {
        let token: String
        weak var engine: WKWebViewTab?
        let screen: ScreenCaptureStream?
        weak var requester: WKWebView?
        let encoder: TabShareEncoder
        var timer: DispatchSourceTimer?
        var seq = 0
        var servedSeq = 0
        var chunk: TabShareEncoder.Chunk?
        /// The page's decoder is (re)starting and can only begin on a keyframe.
        var forceKey = false
        var lastPullAt = ContinuousClock.Instant.now
        var consecutiveFailures = 0
        var consecutiveDuplicates = 0
        var frameInFlight = false
        var degradedCadence = false
        /// The screen stream's frame count at the last encode.
        var encodedScreenFrame = 0

        init(token: String, engine: WKWebViewTab?, screen: ScreenCaptureStream?, requester: WKWebView, encoder: TabShareEncoder) {
            self.token = token
            self.engine = engine
            self.screen = screen
            self.requester = requester
            self.encoder = encoder
        }
    }

    /// 30 fps keeps the whole pipeline (snapshot plus encode) inside the frame budget with margin;
    /// 60 would spend a large share of a core on snapshots alone.
    static let framesPerSecond: Double = 30
    /// Static content (2s of identical snapshots) drops the snapshot cadence to this; the first
    /// changed frame restores full speed, so a slide flip lags at most one idle interval.
    static let idleFramesPerSecond: Double = 10
    static let idleCadenceThreshold = 60
    /// Frame width cap, in pixels: 1080p is the most a call sends.
    static let maxFrameWidth: CGFloat = 1920
    /// Encode-failure teardown threshold (~1.5s of dead snapshots at full cadence).
    static let maxConsecutiveFailures = 45
    /// A shim that stopped pulling (page navigated with no pagehide delivery) ends the session.
    static let pullTimeout: Duration = .seconds(10)

    private var sessions: [String: Session] = [:]
    /// Fired after a session ends, with its token and the shared engine's id (nil for a screen), so
    /// the window controller can detach a share-retained background view.
    var onSessionEnded: ((_ token: String, _ engineId: UUID?) -> Void)?
    /// Fired when a new frame is stored or a session ends; the scheme handler flushes waiters.
    var onFrameStored: (() -> Void)?
    /// Whether the scheme handler holds a pull for this token: a shim waiting on static content.
    var hasParkedPull: ((String) -> Bool)?

    func isSharing(engineId: UUID) -> Bool { sessions.values.contains { $0.engine?.id == engineId } }

    /// The engines ferried as a tab share (for view re-adoption after a space switch).
    var sharedEngines: [WKWebViewTab] { sessions.values.compactMap(\.engine) }

    /// Starts a session for `engine`. Returns the shim reply payload.
    func start(engine: WKWebViewTab, requester: WKWebView) -> [String: Any] {
        // The view's size in pixels, not points: a Retina tab sized in points would be sent at half
        // its resolution, and its text would read blurry on the other side of the call.
        let bounds = engine.view.bounds
        let backingScale = engine.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let sourceSize = bounds.width > 100 && bounds.height > 100
            ? NSSize(width: bounds.width * backingScale, height: bounds.height * backingScale)
            : NSSize(width: Self.maxFrameWidth, height: Self.maxFrameWidth * 9 / 16)
        let scale = min(1, Self.maxFrameWidth / sourceSize.width)
        // H.264 needs even dimensions.
        let width = Int(sourceSize.width * scale) & ~1
        let height = Int(sourceSize.height * scale) & ~1
        engine.isTabShareSource = true
        return start(Session(token: UUID().uuidString, engine: engine, screen: nil, requester: requester, encoder: TabShareEncoder(width: width, height: height)), surface: "browser")
    }

    /// Starts a session ferrying a started screen stream, which the session stops when it ends.
    func start(screen: ScreenCaptureStream, requester: WKWebView) -> [String: Any] {
        let session = Session(token: UUID().uuidString, engine: nil, screen: screen, requester: requester, encoder: TabShareEncoder(width: screen.width, height: screen.height))
        // The token, not the session: the session holds the stream, which holds this closure.
        let token = session.token
        screen.onStop = { [weak self] in self?.stop(token: token) }
        return start(session, surface: screen.surface)
    }

    private func start(_ session: Session, surface: String) -> [String: Any] {
        sessions[session.token] = session
        startTimer(session, framesPerSecond: Self.framesPerSecond)
        return [
            "mode": "tab",
            "surface": surface,
            "token": session.token,
            "width": session.encoder.width,
            "height": session.encoder.height,
            "frameURL": "\(TabShareFrameSchemeHandler.scheme)://frames/frame?token=\(session.token)"
        ]
    }

    /// Scheme-handler read: newest frame after `afterSeq`, pending when none yet, gone when the
    /// token or the pulling web view does not match the live session. Each pull also feeds the
    /// dead-shim watchdog. Frames are served in sequence: capture waits for each to be taken.
    func frame(token: String, afterSeq: Int, wantsKey: Bool, puller: WKWebView) -> TabShareFrameSchemeHandler.FrameResult {
        guard let current = sessions[token], current.requester === puller else { return .gone }
        current.lastPullAt = .now
        if wantsKey, current.chunk?.config == nil || current.seq <= afterSeq {
            // Drop the stored delta (it would reopen nothing without its references) and key the next encode.
            current.forceKey = true
            current.servedSeq = current.seq
            return .pending
        }
        guard let chunk = current.chunk, current.seq > afterSeq else { return .pending }
        current.servedSeq = current.seq
        return .frame(seq: current.seq, chunk: chunk)
    }

    func stop(token: String) {
        guard let ended = sessions.removeValue(forKey: token) else { return }
        ended.timer?.cancel()
        ended.screen?.stop()
        let engineId = ended.engine?.id
        let stillShared = engineId.map(isSharing(engineId:)) == true
        if !stillShared { ended.engine?.isTabShareSource = false }
        ended.requester?.evaluateJavaScript(PageWorld.push("tabShareEnded", [ended.token]), in: nil, in: PageWorld.bridgeWorld)
        onFrameStored?()   // parked pulls resolve to 410 so the shim ends its stream
        onSessionEnded?(token, stillShared ? nil : engineId)
    }

    /// Ends every session sharing `engineId` or requested by `view`.
    func stop(sharing engineId: UUID? = nil, requestedBy view: NSView? = nil) {
        for session in Array(sessions.values) where (engineId != nil && session.engine?.id == engineId) || (view != nil && session.requester === view) {
            stop(token: session.token)
        }
    }

    func stopAll() {
        Array(sessions.keys).forEach(stop(token:))
    }

    private func startTimer(_ session: Session, framesPerSecond: Double) {
        session.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / framesPerSecond, leeway: .milliseconds(5))
        let token = session.token
        timer.setEventHandler { [weak self] in self?.tick(token) }
        timer.resume()
        session.timer = timer
    }

    private func tick(_ token: String) {
        guard let current = sessions[token] else { return }
        // A pull parked on static content is a live shim; only a shim gone silent ends the session.
        let shimAlive = ContinuousClock.Instant.now - current.lastPullAt < Self.pullTimeout
            || hasParkedPull?(current.token) == true
        guard current.requester != nil, shimAlive else {
            stop(token: token)
            return
        }
        // One frame in the pipeline at a time, and none while the page has not taken the last one:
        // a slow encode or a throttled page drops ticks instead of queueing work.
        guard !current.frameInFlight, current.servedSeq == current.seq else { return }
        if let screen = current.screen {
            captureScreenFrame(current, screen: screen)
        } else {
            captureTabFrame(current)
        }
    }

    private func captureScreenFrame(_ current: Session, screen: ScreenCaptureStream) {
        guard let buffer = screen.latestFrame, current.forceKey || screen.frameCount != current.encodedScreenFrame else {
            storeEncodedFrame(.unchanged, token: current.token)
            return
        }
        current.encodedScreenFrame = screen.frameCount
        let forceKey = current.forceKey
        current.forceKey = false
        encode(.pixels(buffer), forceKey: forceKey, session: current)
    }

    private func captureTabFrame(_ current: Session) {
        guard let engine = current.engine, engine.wake(), let webView = engine.view as? WKWebView else {
            stop(token: current.token)
            return
        }
        current.frameInFlight = true
        let forceKey = current.forceKey
        current.forceKey = false
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        // snapshotWidth is in points and the snapshot renders at the display's backing scale, so a
        // Retina screen would return four times the pixels the cap allows. Ask for the point width
        // that lands on the intended pixel width.
        let backingScale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        config.snapshotWidth = NSNumber(value: Double(current.encoder.width) / backingScale)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self, self.sessions[current.token] === current else { return }
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                if forceKey { current.forceKey = true }
                self.registerFailure(token: current.token)
                return
            }
            self.encode(.image(cgImage), forceKey: forceKey, session: current)
        }
    }

    /// CGImage and CVPixelBuffer are immutable here and thread-safe but not Sendable-annotated; the
    /// box carries the frame to the encode task, which is its only consumer.
    private enum Frame: @unchecked Sendable {
        case image(CGImage)
        case pixels(CVPixelBuffer)
    }

    private func encode(_ frame: Frame, forceKey: Bool, session: Session) {
        session.frameInFlight = true
        let encoder = session.encoder, token = session.token
        Task.detached(priority: .userInitiated) {
            let result = switch frame {
            case .image(let image): encoder.encode(image, forceKey: forceKey)
            case .pixels(let buffer): encoder.encode(buffer, forceKey: forceKey)
            }
            await self.storeEncodedFrame(result, forceKey: forceKey, token: token)
        }
    }

    private func storeEncodedFrame(_ result: TabShareEncoder.Result, forceKey: Bool = false, token: String) {
        guard let current = sessions[token] else { return }
        current.frameInFlight = false
        switch result {
        case .failed:
            if forceKey { current.forceKey = true }
            registerFailure(token: token)
        case .unchanged:
            // Static content (slides, docs): keep the stored frame and, past the threshold, drop the
            // snapshot cadence until content changes again.
            current.consecutiveFailures = 0
            current.consecutiveDuplicates += 1
            if current.consecutiveDuplicates >= Self.idleCadenceThreshold && !current.degradedCadence {
                current.degradedCadence = true
                startTimer(current, framesPerSecond: Self.idleFramesPerSecond)
            }
        case .chunk(let chunk):
            current.consecutiveFailures = 0
            current.consecutiveDuplicates = 0
            if current.degradedCadence {
                current.degradedCadence = false
                startTimer(current, framesPerSecond: Self.framesPerSecond)
            }
            current.seq += 1
            current.chunk = chunk
            onFrameStored?()
        }
    }

    private func registerFailure(token: String) {
        guard let current = sessions[token] else { return }
        current.frameInFlight = false
        current.consecutiveFailures += 1
        if current.consecutiveFailures >= Self.maxConsecutiveFailures { stop(token: token) }
    }
}
