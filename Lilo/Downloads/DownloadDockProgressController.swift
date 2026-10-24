import AppKit

/// Updates the Dock icon badge and progress arc while downloads are active.
@MainActor
final class DownloadDockProgressController {

    private var indeterminatePhase: Double = 0

    /// Last badge + arc actually pushed to the Dock, progress rounded to the percent the arc can
    /// show. Progress ticks arrive at 5 Hz per active download and each `display()` redraws a
    /// 128pt view, so identical frames are dropped.
    private var lastRendered: (count: Int, percent: Int)?
    nonisolated(unsafe) private var spinTimer: Timer?

    /// True while a download with unknown size is active, so we can resume the cosmetic spin
    /// after the app returns to the foreground (the timer is paused while backgrounded).
    private var hasIndeterminate = false
    nonisolated(unsafe) private var activeObserver: Any?
    nonisolated(unsafe) private var resignObserver: Any?

    /// Active downloads kept in memory (mirrors BottomBar.svelte's activeDownloads map): each observer
    /// callback carries the changed item, so the Dock derives count + aggregate progress from this dict
    /// rather than re-reading all of download history (incl. blobs) from SQLite on every progress tick.
    private var active: [Int64: DownloadItem] = [:]

    private lazy var progressView = DockProgressView()

    init() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSpinTimer() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSpinTimer() }
        }
    }

    deinit {
        spinTimer?.invalidate()
        [activeObserver, resignObserver].compactMap { $0 }.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func attach(to manager: DownloadManager) {
        manager.addObserver { [weak self] item in self?.update(with: item) }
    }

    private func update(with item: DownloadItem) {
        guard let id = item.id else { return }
        switch item.state {
        case .inProgress, .paused: active[id] = item
        case .complete, .interrupted: active.removeValue(forKey: id)
        }

        let (count, progress) = Self.aggregate(active.values)

        guard count > 0 else {
            hasIndeterminate = false
            lastRendered = nil
            NSApp.dockTile.badgeLabel = nil
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.display()
            stopSpinTimer()
            return
        }

        hasIndeterminate = progress == nil
        syncSpinTimer()

        // -1 marks indeterminate: the spin timer owns those frames, so nothing to redraw here.
        let percent = progress.map { Int($0 * 100) } ?? -1
        guard lastRendered?.count != count || lastRendered?.percent != percent else { return }
        lastRendered = (count, percent)

        NSApp.dockTile.badgeLabel = "\(count)"
        progressView.progress = progress
        progressView.phase = progress == nil ? indeterminatePhase : 0
        NSApp.dockTile.contentView = progressView
        NSApp.dockTile.display()
    }

    /// Badge count + aggregate progress for the Dock. Progress is `nil` (indeterminate) unless every
    /// active download has a known total (`totalBytes > 0`), matching the BottomBar indicator.
    nonisolated static func aggregate<S: Collection>(_ active: S) -> (count: Int, progress: Double?)
    where S.Element == DownloadItem {
        let count = active.count
        guard count > 0 else { return (0, nil) }
        let known = active.filter { $0.totalBytes > 0 }
        guard known.count == count else { return (count, nil) }
        let received = known.reduce(0) { $0 + $1.bytesReceived }
        let total = known.reduce(0) { $0 + $1.totalBytes }
        return (count, total > 0 ? Double(received) / Double(total) : nil)
    }

    /// Starts or pauses the cosmetic spin timer. The timer only redraws a Dock icon, so it runs
    /// only when the app is active (frontmost/visible) AND a download with unknown size is in
    /// flight. Called on download progress changes and on app activate/resign notifications.
    private func syncSpinTimer() {
        if NSApp.isActive && hasIndeterminate {
            startSpinTimerIfNeeded()
        } else {
            stopSpinTimer()
        }
    }

    private func startSpinTimerIfNeeded() {
        guard spinTimer == nil else { return }
        // 6 Hz at ~one rotation per second: coarse enough to stay cheap, smooth enough for a
        // 32pt Dock badge.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.indeterminatePhase = (self.indeterminatePhase + 0.16).truncatingRemainder(dividingBy: 1.0)
                self.progressView.phase = self.indeterminatePhase
                NSApp.dockTile.display()
            }
        }
        timer.tolerance = 0.03
        spinTimer = timer
    }

    private func stopSpinTimer() {
        spinTimer?.invalidate()
        spinTimer = nil
    }
}

extension DownloadDockProgressController {
    /// Draws the app icon with an optional progress arc overlay for the Dock tile.
    final class DockProgressView: NSView {

        var progress: Double? { didSet { needsDisplay = true } }  // nil = indeterminate; 0..1 = determinate
        var phase: Double = 0 { didSet { needsDisplay = true } }  // rotation for indeterminate animation (0..1)

        init() {
            super.init(frame: NSRect(origin: .zero, size: NSSize(width: 128, height: 128)))
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            // Read at draw time: the user can switch to an alternate icon while a download runs.
            NSApp.applicationIconImage?.draw(in: bounds)

            guard let context = NSGraphicsContext.current?.cgContext else { return }

            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius: CGFloat = 52
            let lineWidth: CGFloat = 8

            // Track circle
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(lineWidth)
            context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            context.strokePath()

            // Progress arc (starts at top = π/2, goes clockwise)
            let fillFraction = progress ?? 0.25  // indeterminate: quarter arc
            let startAngle: CGFloat = .pi / 2 + CGFloat(phase) * .pi * 2
            let endAngle = startAngle - CGFloat(fillFraction) * .pi * 2

            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.addArc(center: center, radius: radius,
                           startAngle: startAngle, endAngle: endAngle, clockwise: true)
            context.strokePath()
        }
    }
}
