import AppKit

/// Floats beside System Settings while the user turns Full Disk Access on, holding Lilo's icon to drag into the
/// list when macOS has not listed Lilo yet. It shows only while System Settings is the frontmost app, polls only
/// while it exists, and closes once `isGranted` holds, when System Settings quits, or when the user closes it.
@MainActor
final class FullDiskAccessPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let stack: NSStackView
    private let arrow = NSImageView()
    private let icon = AppIconDragView()
    private let text: NSTextField
    private let isGranted: () -> Bool
    private let onClose: (_ granted: Bool) -> Void
    private var timer: Timer?
    private var ticks = 0
    private var shown = false
    private var observers: [Any] = []
    private var pointsLeft: Bool?

    init(isGranted: @escaping () -> Bool, onClose: @escaping (_ granted: Bool) -> Void) {
        self.isGranted = isGranted
        self.onClose = onClose
        // macOS lists Lilo, switched off, once it has been denied a protected folder: the icon is for when it has not.
        text = NSTextField(wrappingLabelWithString: "Turn Lilo on in the list, or drag this icon into it.".localized)
        text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        text.preferredMaxLayoutWidth = 190
        stack = NSStackView(views: [arrow, icon, text])
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Non-activating: dragging the icon must leave System Settings the active app, its list the drop target.
        panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        arrow.contentTintColor = .controlAccentColor
        arrow.wantsLayer = true
        arrow.setAccessibilityElement(false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // The content starts under the title bar, clear of the close button.
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            arrow.widthAnchor.constraint(equalToConstant: 20)
        ])
        panel.contentView = content
        panel.delegate = self
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.1
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let isSettings = Self.isSettings(note)
                MainActor.assumeIsolated { isSettings ? self?.show() : self?.panel.orderOut(nil) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let isSettings = Self.isSettings(note)
                MainActor.assumeIsolated { if isSettings { self?.close() } }
            }
        ]
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleId { show() }
    }

    isolated deinit {
        timer?.invalidate()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        panel.orderOut(nil)
    }

    private nonisolated static let settingsBundleId = "com.apple.systempreferences"

    private nonisolated static func isSettings(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == settingsBundleId
    }

    func close(granted: Bool = false) {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        panel.close()
        onClose(granted)
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    private func tick() {
        if isGranted() { return close(granted: true) }
        ticks += 1
        // Also follows the window while the user moves it, and places the panel once a launching System Settings shows its window.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleId {
            show()
        } else if !shown && ticks > 20 {
            close()
        }
    }

    private func show() {
        guard timer != nil else { return }
        guard let settings = Self.settingsWindowFrame() else { return }
        shown = true
        place(beside: settings)
    }

    /// The frontmost System Settings window, in AppKit screen coordinates. Window bounds need no Screen Recording permission.
    private static func settingsWindowFrame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleId).map(\.processIdentifier))
        guard !pids.isEmpty, let primary = NSScreen.screens.first?.frame,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 300, rect.height > 300 else { continue }
            return NSRect(x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }

    /// To the right of the window, else to its left, else over its bottom right corner; the arrow points at the list.
    private func place(beside settings: NSRect) {
        let visible = (NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main)?.visibleFrame ?? settings
        let gap: CGFloat = 12
        let width = panel.contentView?.fittingSize.width ?? 0
        let fitsRight = settings.maxX + gap + width <= visible.maxX
        let left = fitsRight || settings.minX - gap - width < visible.minX
        if pointsLeft != left {
            pointsLeft = left
            arrow.image = NSImage(systemSymbolName: left ? "arrow.left" : "arrow.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
            stack.setViews(left ? [arrow, icon, text] : [icon, text, arrow], in: .leading)
            panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        }
        let size = panel.frame.size
        var origin = NSPoint(x: fitsRight ? settings.maxX + gap : settings.minX - gap - size.width, y: settings.midY - size.height / 2)
        if !fitsRight && left {
            origin = NSPoint(x: settings.maxX - size.width - gap, y: settings.minY + gap)
        }
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        nudgeArrow()
    }

    /// A few nudges toward the list as the panel appears, then it rests.
    private func nudgeArrow() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = arrow.layer else { return }
        let nudge = CABasicAnimation(keyPath: "transform.translation.x")
        nudge.fromValue = 0
        nudge.toValue = pointsLeft == false ? 6 : -6
        nudge.duration = 0.45
        nudge.autoreverses = true
        nudge.repeatCount = 3
        nudge.beginTime = CACurrentMediaTime() + 0.2
        nudge.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(nudge, forKey: "nudge")
    }
}

/// Lilo's icon, dragged as the app bundle's file URL: what System Settings' privacy lists accept.
private final class AppIconDragView: NSView, NSDraggingSource {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Lilo")
        toolTip = "Drag into the Full Disk Access list".localized
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}
