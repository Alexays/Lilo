import AppKit
import WebKit

/// A page's alert, confirm, prompt or sign-in as Chrome's tab-modal dialogs: a panel over its own page only, which
/// it blocks, inside the page's web view so it follows the tab wherever it shows and keeps what was typed while the
/// tab is away. `completion` runs once: true for the default button, false for Cancel, Escape or a dismissal.
@MainActor
final class TabModalDialogView: NSView {
    /// Set by the tab, after `completion`.
    var onFinish: (() -> Void)?
    private var completion: (@MainActor (Bool) -> Void)?
    private let initialResponder: NSView
    /// What had the keyboard when the tab went away, given it back when the tab shows again.
    private weak var lastResponder: NSView?
    private let announcement: String

    private static let contentWidth: CGFloat = 260
    private static let inset: CGFloat = 20
    /// Taller messages scroll inside the panel.
    private static let maxMessageHeight: CGFloat = 320

    /// `accessories` (text fields, checkboxes) stack full width between the message and the buttons; the caller
    /// keeps them to read their values in `completion`.
    init(
        title: String,
        message: String,
        accessories: [NSView] = [],
        acceptTitle: String,
        cancelTitle: String?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        // Drawn as the default button without its "\r" key equivalent: the window would make it its default button,
        // which Return pressed anywhere in the window answers, even in another split pane.
        let accept = NSButton(title: acceptTitle, target: nil, action: #selector(accept(_:)))
        accept.tintProminence = .primary
        var buttons = [accept]
        if let cancelTitle { buttons.insert(NSButton(title: cancelTitle, target: nil, action: #selector(cancel(_:))), at: 0) }
        let fields = accessories.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        initialResponder = fields.first ?? accept
        announcement = message.isEmpty ? title : "\(title), \(message)"
        self.completion = completion
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        alphaValue = 0

        for button in buttons {
            button.target = self
            button.controlSize = .large
        }
        // Return in a field answers as the default button does; leaving the field (the tab goes away) does not.
        for field in fields {
            field.target = self
            field.action = #selector(accept(_:))
            field.cell?.sendsActionOnEndEditing = false
        }

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .center
        titleLabel.isSelectable = false
        var rows: [NSView] = [titleLabel]
        var messageHeight: NSLayoutConstraint?
        if !message.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let text = NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ])
            let height = ceil(text.boundingRect(
                with: NSSize(width: Self.contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
            let messageView = NSTextView(usingTextLayoutManager: false)
            messageView.textStorage?.setAttributedString(text)
            messageView.isEditable = false
            messageView.drawsBackground = false
            messageView.textContainerInset = .zero
            messageView.textContainer?.lineFragmentPadding = 0
            messageView.textContainer?.widthTracksTextView = true
            messageView.isVerticallyResizable = true
            messageView.autoresizingMask = .width
            messageView.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: height)
            let scroll = NSScrollView()
            scroll.documentView = messageView
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            // Its full height unless the page is too short for it: then it scrolls.
            let fitting = scroll.heightAnchor.constraint(equalToConstant: min(height, Self.maxMessageHeight))
            fitting.priority = .defaultHigh - 1
            messageHeight = fitting
            rows.append(scroll)
        }
        rows += accessories
        let buttonRow = NSStackView(views: buttons)
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8
        rows.append(buttonRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(Self.inset, after: rows[rows.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSBox()
        panel.boxType = .custom
        panel.titlePosition = .noTitle
        panel.fillColor = .windowBackgroundColor
        panel.borderColor = .separatorColor
        panel.borderWidth = 1
        panel.cornerRadius = 16
        panel.contentViewMargins = .zero
        panel.wantsLayer = true
        panel.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            return shadow
        }()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        addSubview(panel)

        let width = panel.widthAnchor.constraint(equalToConstant: Self.contentWidth + 2 * Self.inset)
        width.priority = .defaultHigh
        var constraints = [
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            width
        ]
        // Below required: a background tab's web view may still have no size.
        for margin in [
            panel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16)
        ] {
            margin.priority = .required - 1
            constraints.append(margin)
        }
        constraints += rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset) }
        // A checkbox's title wraps, as a long translation of "Prevent this page..." needs; its height is not its own.
        for box in accessories.compactMap({ $0 as? NSButton }) {
            box.cell?.wraps = true
            box.lineBreakMode = .byWordWrapping
            let size = box.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.contentWidth, height: .greatestFiniteMagnitude))
            constraints.append(box.heightAnchor.constraint(equalToConstant: ceil(size?.height ?? 18)))
        }
        if let messageHeight { constraints.append(messageHeight) }
        NSLayoutConstraint.activate(constraints)

        // Tab cycles through the dialog only: the page under it never takes the keyboard.
        let keyViews = accessories.filter { $0 is NSControl } + buttons
        for (index, view) in keyViews.enumerated() { view.nextKeyView = keyViews[(index + 1) % keyViews.count] }
        nextKeyView = keyViews.first

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(title)
        setAccessibilityModal(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Covers `webView`'s page, and takes the keyboard when the page is on screen.
    func show(in webView: WKWebView) {
        frame = webView.bounds
        // Takes every drop the page would, to refuse it.
        registerForDraggedTypes(webView.registeredDraggedTypes)
        webView.addSubview(self, positioned: .above, relativeTo: nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }
        focus()
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    /// Gives the dialog the keyboard: what had it last, else its first field or default button, else the dialog
    /// itself, which answers Return and Escape when keyboard navigation leaves buttons out of focus.
    @discardableResult
    func focus() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(lastResponder ?? initialResponder) || window.makeFirstResponder(self)
    }

    /// Answers false, as Cancel would: the tab closes or navigates away.
    func dismiss() { finish(false) }

    private func finish(_ accepted: Bool) {
        guard let completion else { return }
        self.completion = nil
        let page = superview
        let hadKeyboard = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        let window = window
        removeFromSuperview()
        if hadKeyboard, let page { window?.makeFirstResponder(page) }
        completion(accepted)
        onFinish?()
    }

    @objc private func accept(_ sender: Any?) { finish(true) }
    @objc private func cancel(_ sender: Any?) { finish(false) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, let responder = window?.firstResponder as? NSView else { return }
        // A field being edited hands the window its field editor, which is not kept.
        let held = (responder as? NSText)?.delegate as? NSView ?? responder
        if held.isDescendant(of: self) { lastResponder = held }
    }

    // Keys reach the dialog only while it has the keyboard: the window offers key equivalents to every view.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else { return false }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.keyCode {
        case 36, 76: finish(true)
        case 53: finish(false)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: finish(true)
        case 53: finish(false)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { finish(false) }

    // The page under the dialog gets no pointer input: a click outside the panel only brings the keyboard back.
    override func mouseDown(with event: NSEvent) {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { return }
        focus()
    }

    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor.black.withAlphaComponent(isDark ? 0.4 : 0.2).cgColor
    }
}

/// A tab's web view. While a tab-modal dialog covers the page, the page takes no keyboard, and the dialog stands in
/// for it with VoiceOver, to which WebKit hands only the page's own element.
final class PageWebView: WKWebView {
    private var modalDialog: TabModalDialogView? {
        subviews.last { $0 is TabModalDialogView } as? TabModalDialogView
    }

    override var acceptsFirstResponder: Bool { modalDialog == nil && super.acceptsFirstResponder }

    override func accessibilityChildren() -> [Any]? {
        modalDialog.map { [$0] } ?? super.accessibilityChildren()
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        modalDialog?.accessibilityHitTest(point) ?? super.accessibilityHitTest(point)
    }

    // WebKit answers VoiceOver through this older entry point, so the dialog must be listed here too.
    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if attribute == .children, let modalDialog { return [modalDialog] }
        return super.accessibilityAttributeValue(attribute)
    }
}
