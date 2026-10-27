import AppKit
import CoreServices
import OSLog

/// A repository's changes: a header with the mode and layout, then two cards on the window's frame
/// color, the changed files grouped by folder and every file's diff in one scrolling stream. It
/// reloads by itself while on screen, when files change.
@MainActor
final class ChangesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let headerHeight: CGFloat = 44
    /// The gap around and between the cards, as around the window's content.
    private static let gap: CGFloat = 8
    private static let fileListWidth: CGFloat = 264
    /// Below this width the file list gives its room to the diff.
    private static let fileListMinimumWidth: CGFloat = 760
    private static let loadQueue = DispatchQueue(label: "fr.arouillard.lilo.changes", qos: .utility)
    private static let reloadGap: TimeInterval = 2

    /// The repository root, or the worktree picked in the header.
    private(set) var repository: String
    /// The main repository's name, also in one of its linked worktrees.
    private let repositoryName: String
    private var isLinkedWorktree: Bool
    /// The worktree menu while it is open, its counts filled in as git reports them.
    private var worktreeMenu: NSMenu?
    /// Bumped as each worktree menu closes, so its counts stop.
    private var worktreeMenuGeneration = 0
    var onOpenInSplit: (() -> Void)?
    var onClose: (() -> Void)?
    /// "Open in Split" and the close button, shown while the view is a peek.
    var showsPeekControls = false {
        didSet {
            splitButton.isHidden = !showsPeekControls
            closeButton.isHidden = !showsPeekControls
            needsLayout = true
        }
    }

    var diffView: ChangesDiffView { diffDocument }

    /// A row of the file list: a folder heading the files under it, or a file.
    private enum ListItem {
        case folder(String, count: Int)
        case file(Int)
    }

    private var mode = GitDiff.Mode.uncommitted
    private var diff: GitDiff?
    private var failed = false
    private var shownBranch: String?
    private var generation = 0
    private var isLoading = false
    private var reloadAgain = false
    /// The reload asked for during a load, waiting out `reloadGap` after it.
    private var followUp: DispatchWorkItem?
    private var watcher: RepositoryWatcher?
    private var occlusionObserver: NSObjectProtocol?
    private var syncingSelection = false
    private var listItems: [ListItem] = []
    /// Per file, its row in the list; -1 while its folder is collapsed.
    private var listRows: [Int] = []
    private var collapsedFolders: Set<String> = []

    private let titleLabel = NSTextField(labelWithString: "Changes".localized)
    private let repositoryLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let countsChip = ChangesCountsChip()
    private let modeControl = ChangesSegmentedControl(labels: ["Uncommitted".localized, "Branch".localized])
    private let layoutControl = ChangesSegmentedControl(labels: ["Unified".localized, "Split".localized])
    private lazy var splitButton = iconButton("rectangle.split.2x1", label: "Open in Split".localized, action: #selector(openInSplitAction(_:)))
    private lazy var closeButton = iconButton("xmark", label: "Close".localized, action: #selector(closeAction(_:)))
    private let listCard = NSView()
    private let fileTable = NSTableView()
    private let fileScroll = NSScrollView()
    private let diffCard = NSView()
    private let diffScroll = NSScrollView()
    private let diffDocument = ChangesDiffView()
    private let stickyHeader = ChangesStickyHeader()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(labelWithString: "")
    private lazy var emptyButton = NSButton(title: "", target: self, action: #selector(emptyButtonAction(_:)))
    private let spinner = NSProgressIndicator()

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// The window's frame color under the cards, its content surface on the file list.
    override func updateLayer() {
        let frame = window?.backgroundColor ?? .windowBackgroundColor
        layer?.backgroundColor = frame.cgColor
        listCard.layer?.backgroundColor = frame.contentSurfaceColor.cgColor
    }

    init(directory: String) {
        repository = GitDiff.repositoryRoot(containing: directory) ?? directory
        let directories = GitDiff.gitDirectories(of: repository)
        isLinkedWorktree = directories.own != directories.common
        // The common directory is the main repository's .git, or a bare repository's own folder.
        let common = URL(fileURLWithPath: directories.common)
        repositoryName = isLinkedWorktree
            ? (common.lastPathComponent == ".git" ? common.deletingLastPathComponent().lastPathComponent : common.deletingPathExtension().lastPathComponent)
            : URL(fileURLWithPath: repository).lastPathComponent
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        repositoryLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        repositoryLabel.textColor = .secondaryLabelColor
        repositoryLabel.lineBreakMode = .byTruncatingMiddle
        repositoryLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showWorktreeMenu(_:))))
        countLabel.font = .systemFont(ofSize: 11.5)
        countLabel.textColor = .tertiaryLabelColor
        modeControl.onChange = { [weak self] in self?.modeChanged() }
        modeControl.setAccessibilityLabel("Comparison".localized)
        layoutControl.onChange = { [weak self] in self?.layoutChanged() }
        layoutControl.setAccessibilityLabel("Diff Layout".localized)

        for card in [listCard, diffCard] {
            card.wantsLayer = true
            card.layer?.cornerRadius = WindowFrameView.contentCornerRadius
            card.layer?.masksToBounds = true
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        fileTable.addTableColumn(column)
        fileTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        fileTable.headerView = nil
        fileTable.intercellSpacing = .zero
        fileTable.style = .plain
        fileTable.backgroundColor = .clear
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.target = self
        fileTable.action = #selector(fileClicked(_:))
        fileScroll.documentView = fileTable
        fileScroll.hasVerticalScroller = true
        fileScroll.drawsBackground = false
        fileScroll.autohidesScrollers = true
        fileScroll.horizontalScrollElasticity = .none
        fileScroll.automaticallyAdjustsContentInsets = false
        fileScroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        listCard.addSubview(fileScroll)

        diffScroll.documentView = diffDocument
        diffScroll.hasVerticalScroller = true
        diffScroll.hasHorizontalScroller = true
        diffScroll.autohidesScrollers = true
        diffScroll.drawsBackground = true
        diffScroll.backgroundColor = ChangesDiffView.palette.background
        diffScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(diffScrolled(_:)), name: NSView.boundsDidChangeNotification, object: diffScroll.contentView
        )
        diffDocument.onRowsChange = { [weak self] in self?.relayoutDiff() }
        stickyHeader.diffView = diffDocument
        diffCard.addSubview(diffScroll)
        diffCard.addSubview(stickyHeader)

        emptyTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        emptyButton.bezelStyle = .push
        emptyButton.controlSize = .regular
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.sizeToFit()

        for view in [titleLabel, repositoryLabel, countLabel, countsChip, modeControl, layoutControl, splitButton, closeButton,
                     listCard, diffCard, emptyTitle, emptyDetail, emptyButton, spinner] {
            addSubview(view)
        }
        refreshRepositoryLabel()
        showState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.isHidden = true
        return button
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let midY = Self.headerHeight / 2
        let centered = { (view: NSView) in view.frame.origin.y = (midY - view.frame.height / 2).rounded() }
        titleLabel.sizeToFit()
        titleLabel.frame.origin.x = 16
        centered(titleLabel)

        var trailing = width - 12
        if showsPeekControls {
            for button in [closeButton, splitButton] {
                button.frame = NSRect(x: trailing - 26, y: midY - 13, width: 26, height: 26)
                trailing = button.frame.minX - 2
            }
            trailing -= 8
        }
        for control in [layoutControl, modeControl] {
            control.frame.size = control.intrinsicContentSize
            control.frame.origin.x = trailing - control.frame.width
            centered(control)
            trailing = control.frame.minX - 8
        }

        // Title, repository and branch, then the counts: the repository gives way first.
        countLabel.sizeToFit()
        let chipSize = countsChip.isHidden ? .zero : countsChip.intrinsicContentSize
        let countsWidth = countLabel.frame.width + (countsChip.isHidden ? 0 : 6 + chipSize.width)
        let repositoryX = titleLabel.frame.maxX + 8
        repositoryLabel.sizeToFit()
        repositoryLabel.frame.size.width = max(0, min(repositoryLabel.frame.width, trailing - 16 - countsWidth - repositoryX))
        repositoryLabel.frame.origin.x = repositoryX
        centered(repositoryLabel)
        countLabel.frame.origin.x = repositoryLabel.frame.maxX + 12
        centered(countLabel)
        countsChip.frame = NSRect(origin: NSPoint(x: countLabel.frame.maxX + 6, y: (midY - chipSize.height / 2).rounded()), size: chipSize)

        let gap = Self.gap
        let top = Self.headerHeight
        let bodyHeight = max(0, bounds.height - top - gap)
        let showsList = width >= Self.fileListMinimumWidth && (diff?.files.isEmpty == false)
        listCard.isHidden = !showsList || diffCard.isHidden
        let listWidth = showsList ? Self.fileListWidth : 0
        listCard.frame = NSRect(x: gap, y: top, width: listWidth, height: bodyHeight)
        fileScroll.frame = listCard.bounds
        let diffX = showsList ? listCard.frame.maxX + gap : gap
        diffCard.frame = NSRect(x: diffX, y: top, width: max(0, width - diffX - gap), height: bodyHeight)
        // An unflipped card: the scroll view fills it and the sticky header hugs its top edge.
        diffScroll.frame = diffCard.bounds
        stickyHeader.frame = NSRect(
            x: 0, y: diffCard.bounds.height - diffDocument.rowHeight,
            width: diffCard.bounds.width - (diffScroll.verticalScroller?.frame.width ?? 0), height: diffDocument.rowHeight
        )
        fileTable.sizeLastColumnToFit()

        emptyTitle.sizeToFit()
        emptyDetail.sizeToFit()
        emptyButton.sizeToFit()
        let centerY = top + bodyHeight / 2
        emptyTitle.frame = NSRect(x: 16, y: centerY - 40, width: width - 32, height: emptyTitle.frame.height)
        emptyDetail.frame = NSRect(x: 16, y: emptyTitle.frame.maxY + 6, width: width - 32, height: emptyDetail.frame.height)
        emptyButton.frame.origin = NSPoint(x: ((width - emptyButton.frame.width) / 2).rounded(), y: emptyDetail.frame.maxY + 14)
        spinner.frame.origin = NSPoint(x: ((width - spinner.frame.width) / 2).rounded(), y: (centerY - spinner.frame.height / 2).rounded())
        relayoutDiff()
    }

    private func relayoutDiff() {
        diffDocument.fit(toWidth: diffScroll.contentSize.width, height: diffScroll.contentSize.height)
        refreshSticky()
    }

    // MARK: - Loading

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            watcher = nil
            return
        }
        needsDisplay = true
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWatching() }
        }
        updateWatching()
    }

    /// Off screen, hidden or covered, nothing watches the disk; back in view the view catches up at once.
    private func updateWatching() {
        let visible = window?.occlusionState.contains(.visible) == true
        guard visible != (watcher != nil) else { return }
        watcher = visible ? RepositoryWatcher(root: repository) { [weak self] in self?.reload() } : nil
        if visible { reload() }
    }

    /// Runs git off the main thread; a request made while a load runs is served once it ends.
    func reload() {
        // A follow-up already waits for its gap and will see this change too.
        guard followUp == nil else { return }
        guard !isLoading else {
            reloadAgain = true
            return
        }
        isLoading = true
        generation += 1
        let generation = generation, repository = repository, mode = mode
        let signpost = PerfSignposts.energy.beginInterval("changesReload", id: PerfSignposts.energy.makeSignpostID())
        if diff == nil {
            // Only a load that keeps the view blank for a moment shows the spinner, so a quick one never flashes it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, isLoading, diff == nil, !failed else { return }
                    spinner.startAnimation(nil)
                }
            }
        }
        Self.loadQueue.async {
            var diff = GitDiff.load(in: repository, mode: mode)
            // Grouped by folder, files at the root first: the list and the diff read in the same order.
            diff?.files.sort { a, b in
                let first = (a.path as NSString).deletingLastPathComponent, second = (b.path as NSString).deletingLastPathComponent
                guard first != second else { return a.path < b.path }
                return first.isEmpty || (!second.isEmpty && first < second)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    PerfSignposts.energy.endInterval("changesReload", signpost)
                    guard let self else { return }
                    isLoading = false
                    let unchanged: Bool
                    if let diff, let shown = self.diff {
                        unchanged = diff.bytes == shown.bytes && diff.base == shown.base && diff.mergeBase == shown.mergeBase
                            && diff.files.elementsEqual(shown.files) { $0.path == $1.path && $0.isBinary == $1.isBinary }
                    } else {
                        unchanged = diff == nil && failed
                    }
                    // A reload that finds what is shown leaves the view alone: no rebuild, no layout.
                    if generation == self.generation, !unchanged || TerminalSession.gitBranch(in: repository) != shownBranch { apply(diff) }
                    guard reloadAgain else { return }
                    reloadAgain = false
                    // A load dropped by a restart is followed at once; a steady writer waits a gap between loads.
                    guard generation == self.generation else { return reload() }
                    let followUp = DispatchWorkItem {
                        MainActor.assumeIsolated { [weak self] in
                            self?.followUp = nil
                            self?.reload()
                        }
                    }
                    self.followUp = followUp
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadGap, execute: followUp)
                }
            }
        }
    }

    private func apply(_ diff: GitDiff?) {
        // The row at the top stays at the top: a reload under the reader never moves the text.
        let anchor = diffDocument.anchor()
        spinner.stopAnimation(nil)
        failed = diff == nil
        self.diff = diff
        diffDocument.diff = diff
        rebuildList()
        refreshRepositoryLabel()
        showState()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let anchor { diffDocument.restore(anchor) }
        refreshSticky()
    }

    private func refreshRepositoryLabel() {
        let branch = TerminalSession.gitBranch(in: repository)
        shownBranch = branch
        let font = repositoryLabel.font ?? .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let value = NSMutableAttributedString(string: repositoryName, attributes: [.font: font])
        if isLinkedWorktree {
            value.append(NSAttributedString(string: " ", attributes: [.font: font]))
            value.append(NSAttributedString(attachment: Self.worktreeChip(font: font)))
        }
        if let branch { value.append(NSAttributedString(string: (isLinkedWorktree ? " " : " · ") + branch, attributes: [.font: font])) }
        // The chevron says a click picks another worktree.
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Switch Worktree".localized)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            attachment.bounds = NSRect(origin: NSPoint(x: 0, y: ((font.capHeight - chevron.size.height) / 2).rounded()), size: chevron.size)
            value.append(NSAttributedString(string: " ", attributes: [.font: font]))
            value.append(NSAttributedString(attachment: attachment))
        }
        repositoryLabel.attributedStringValue = value
        repositoryLabel.toolTip = isLinkedWorktree ? repository : nil
    }

    /// The repository's worktrees, the one shown checked; each gets its counts once git has them.
    @objc private func showWorktreeMenu(_ sender: Any?) {
        let repository = repository
        Self.loadQueue.async {
            let worktrees = GitDiff.worktrees(of: repository)
            let branches = worktrees.map { TerminalSession.gitBranch(in: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.repository == repository, worktreeMenu == nil else { return }
                    guard !worktrees.isEmpty else { return NSSound.beep() }
                    let menu = NSMenu()
                    let current = URL(fileURLWithPath: repository).resolvingSymlinksInPath().path
                    for (index, path) in worktrees.enumerated() {
                        let item = NSMenuItem(title: "", action: #selector(worktreePicked(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = path
                        item.toolTip = path
                        item.state = URL(fileURLWithPath: path).resolvingSymlinksInPath().path == current ? .on : .off
                        item.attributedTitle = Self.worktreeTitle(path, branch: branches[index], counts: nil)
                        menu.addItem(item)
                    }
                    worktreeMenu = menu
                    countWorktrees(worktrees, branches: branches, from: 0, menu: worktreeMenuGeneration)
                    // Main-queue blocks still run while the menu tracks, so the counts appear in it.
                    menu.popUp(positioning: nil, at: NSPoint(x: repositoryLabel.frame.minX, y: repositoryLabel.frame.maxY + 4), in: self)
                    worktreeMenu = nil
                    worktreeMenuGeneration += 1
                }
            }
        }
    }

    /// Counts one worktree at a time on the load queue, the next once the last is shown, until the menu closes.
    private func countWorktrees(_ worktrees: [String], branches: [String?], from index: Int, menu generation: Int) {
        guard index < worktrees.count else { return }
        let path = worktrees[index]
        Self.loadQueue.async {
            let counts = GitDiff.stat(in: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, generation == worktreeMenuGeneration, let menu = worktreeMenu else { return }
                    if let counts { menu.items[index].attributedTitle = Self.worktreeTitle(path, branch: branches[index], counts: counts) }
                    countWorktrees(worktrees, branches: branches, from: index + 1, menu: generation)
                }
            }
        }
    }

    /// The worktree's folder name, then its branch dimmed and its counts; a clean worktree shows none.
    private static func worktreeTitle(_ path: String, branch: String?, counts: (added: Int, removed: Int)?) -> NSAttributedString {
        let value = NSMutableAttributedString(string: URL(fileURLWithPath: path).lastPathComponent, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        let small = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        if let branch {
            value.append(NSAttributedString(string: "  " + branch, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        if let counts, counts.added + counts.removed > 0 {
            let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            value.append(NSAttributedString(string: "  +\(counts.added.formatted())", attributes: [.font: digits, .foregroundColor: ChangesColors.added]))
            value.append(NSAttributedString(string: " -\(counts.removed.formatted())", attributes: [.font: digits, .foregroundColor: ChangesColors.removed]))
        }
        return value
    }

    @objc private func worktreePicked(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, path != repository else { return }
        repository = path
        let directories = GitDiff.gitDirectories(of: path)
        isLinkedWorktree = directories.own != directories.common
        collapsedFolders = []
        if window?.occlusionState.contains(.visible) == true { watcher = RepositoryWatcher(root: path) { [weak self] in self?.reload() } }
        refreshRepositoryLabel()
        restart()
    }

    /// The "worktree" chip after the repository name, in the counts chip's style.
    private static func worktreeChip(font: NSFont) -> NSTextAttachment {
        let text = NSAttributedString(string: "worktree".localized, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        let textSize = text.size()
        let size = NSSize(width: ceil(textSize.width) + 10, height: 15)
        // Drawn on demand, so the colors follow the appearance.
        let image = NSImage(size: size, flipped: false) { bounds in
            ChangesColors.chip.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            text.draw(at: NSPoint(x: 5, y: ((bounds.height - textSize.height) / 2).rounded()))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centered on the capitals rather than sitting on the baseline.
        attachment.bounds = NSRect(origin: NSPoint(x: 0, y: ((font.capHeight - size.height) / 2).rounded()), size: size)
        return attachment
    }

    /// Repaints with the current palette, after a change of terminal theme.
    func applyPalette() {
        diffScroll.backgroundColor = ChangesDiffView.palette.background
        diffDocument.needsDisplay = true
        stickyHeader.needsDisplay = true
    }

    /// The counts in the header, or the empty state when there is nothing to show.
    private func showState() {
        let files = diff?.files ?? []
        let isEmpty = files.isEmpty
        diffCard.isHidden = isEmpty
        listCard.isHidden = isEmpty
        countLabel.isHidden = isEmpty
        countsChip.isHidden = isEmpty
        emptyTitle.isHidden = !isEmpty || (diff == nil && !failed)
        emptyDetail.isHidden = emptyTitle.isHidden
        emptyButton.isHidden = emptyTitle.isHidden || failed
        if failed {
            emptyTitle.stringValue = "Lilo could not read this repository.".localized
            emptyDetail.stringValue = mode == .branch
                ? "No main or master branch to compare with.".localized
                : "Check that git is installed and the folder is a repository.".localized
        } else if mode == .uncommitted {
            emptyTitle.stringValue = "No uncommitted changes".localized
            emptyDetail.stringValue = "The working tree matches the last commit.".localized
            emptyButton.title = "Compare with Branch Base".localized
        } else {
            emptyTitle.stringValue = "No changes on this branch".localized
            emptyDetail.stringValue = String(format: "Nothing differs from %@.".localized, diff?.base ?? "main")
            emptyButton.title = "Show Uncommitted Changes".localized
        }

        var against: String?
        if let base = diff?.base, let mergeBase = diff?.mergeBase {
            against = String(format: "against %@ from %@, uncommitted included".localized, base, mergeBase)
        }
        modeControl.toolTip = against
        countsChip.toolTip = against
        guard let diff, !isEmpty else { return }
        countLabel.stringValue = files.count == 1 ? "1 file".localized : String(format: "%@ files".localized, files.count.formatted())
        countsChip.set(added: diff.added, removed: diff.removed)
    }

    // MARK: - Scrolling

    @objc private func diffScrolled(_ notification: Notification) {
        refreshSticky()
        syncListSelection()
    }

    /// Selects the file at the top of the diff, or nothing while its folder is collapsed.
    private func syncListSelection() {
        guard let file = diffDocument.fileIndex(atY: diffScroll.contentView.bounds.minY), file < listRows.count else { return }
        let row = listRows[file]
        guard row != fileTable.selectedRow else { return }
        syncingSelection = true
        if row >= 0 {
            fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            fileTable.scrollRowToVisible(row)
        } else {
            fileTable.deselectAll(nil)
        }
        syncingSelection = false
    }

    private func refreshSticky() {
        let top = diffScroll.contentView.bounds.minY
        stickyHeader.file = top > 0 ? diffDocument.fileIndex(atY: top) : nil
        stickyHeader.isHidden = stickyHeader.file == nil || diffCard.isHidden
    }

    // MARK: - File list

    /// Each folder heads its files; files at the root come first, under no heading.
    private func rebuildList() {
        let files = diff?.files ?? []
        listItems = []
        listRows = [Int](repeating: -1, count: files.count)
        var start = 0
        while start < files.count {
            let folder = (files[start].path as NSString).deletingLastPathComponent
            var end = start + 1
            while end < files.count, (files[end].path as NSString).deletingLastPathComponent == folder { end += 1 }
            if !folder.isEmpty { listItems.append(.folder(folder, count: end - start)) }
            if folder.isEmpty || !collapsedFolders.contains(folder) {
                for file in start..<end {
                    listRows[file] = listItems.count
                    listItems.append(.file(file))
                }
            }
            start = end
        }
        syncingSelection = true
        fileTable.reloadData()
        syncingSelection = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        listItems.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .folder = listItems[row] { return row == 0 ? 24 : 30 }
        return 26
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: ChangesListRowView.identifier, owner: nil) as? ChangesListRowView ?? ChangesListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let diff else { return nil }
        let cell = tableView.makeView(withIdentifier: ChangesListCell.identifier, owner: nil) as? ChangesListCell ?? ChangesListCell()
        switch listItems[row] {
        case let .folder(path, count):
            cell.content = .folder(path, count: count, collapsed: collapsedFolders.contains(path))
            cell.onToggle = { [weak self] in self?.toggleFolder(path) }
        case let .file(index):
            cell.content = .file(diff.files[index])
            cell.onToggle = nil
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = listItems[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, fileTable.selectedRow >= 0, case let .file(index) = listItems[fileTable.selectedRow] else { return }
        diffDocument.scrollToFile(index)
    }

    /// A folder folds or unfolds its files. A click on the file already selected changes no
    /// selection, yet still jumps back to its diff.
    @objc private func fileClicked(_ sender: Any?) {
        let row = fileTable.clickedRow
        guard row >= 0 else { return }
        switch listItems[row] {
        case let .folder(path, _):
            toggleFolder(path)
        case let .file(index):
            diffDocument.scrollToFile(index)
        }
    }

    private func toggleFolder(_ path: String) {
        if collapsedFolders.remove(path) == nil { collapsedFolders.insert(path) }
        rebuildList()
        syncListSelection()
    }

    // MARK: - Actions

    private func modeChanged() {
        mode = modeControl.selectedSegment == 1 ? .branch : .uncommitted
        restart()
    }

    /// Clears the diff and loads it again, dropping any load still running for what was shown.
    private func restart() {
        followUp?.cancel()
        followUp = nil
        generation += 1
        diff = nil
        failed = false
        diffDocument.diff = nil
        diffDocument.scroll(.zero)
        showState()
        reload()
    }

    private func layoutChanged() {
        let anchor = diffDocument.anchor()
        diffDocument.isSplit = layoutControl.selectedSegment == 1
        relayoutDiff()
        if let anchor { diffDocument.restore(anchor) }
    }

    @objc private func emptyButtonAction(_ sender: Any?) {
        modeControl.selectedSegment = mode == .uncommitted ? 1 : 0
        modeChanged()
    }

    @objc private func openInSplitAction(_ sender: Any?) { onOpenInSplit?() }
    @objc private func closeAction(_ sender: Any?) { onClose?() }
}

// MARK: - Diff

/// Every file's diff as fixed-height rows, drawn with Core Text for the rows in view only. Lines are
/// shaped when first drawn and kept until the diff changes.
@MainActor
final class ChangesDiffView: NSView {
    enum RowKind: UInt8 {
        /// `image` rows are one block: the file's versions drawn across all of them.
        case gap, file, collapsed, hunk, line, image
    }

    /// One row on screen. A line row shows `left` and `right` side by side when split; unified, it
    /// shows `left` alone.
    struct Row {
        var kind: RowKind
        var file: Int32
        var left: Int32 = -1
        var right: Int32 = -1
    }

    /// Where the reader is: a file, a row within it and the pixels past that row's top.
    struct Anchor {
        var path: String
        var row: Int
        var offset: CGFloat
    }

    var diff: GitDiff? {
        didSet {
            // A reload follows a change on disk: the working tree's images are read again.
            images.removeAllObjects()
            unreadableImages = []
            rebuild()
        }
    }
    var isSplit = false {
        didSet { if isSplit != oldValue { rebuild() } }
    }
    /// A file folded or unfolded by a click.
    var onRowsChange: (() -> Void)?

    private(set) var rowHeight: CGFloat = 18
    private var rows: [Row] = []
    private var fileRows: [Int] = []
    /// Per line, the line it replaces or is replaced by, for word highlights; -1 when none.
    private var partners: [Int32] = []
    /// Paths whose fold the reader flipped from the default; kept across reloads.
    private var toggledPaths: Set<String> = []
    private var shapedLines: [Int: Shaped] = [:]
    private var numberWidth: CGFloat = 30
    private var widestLine = 0
    private var selection: ClosedRange<Int>?
    private var selectionAnchor: Int?
    /// Split layout: the selection started on the new (right) side, so a copy takes that side's lines.
    private var selectsNewSide = false
    /// Versions of the images read so far, keyed by commit and path, or by path in the working
    /// tree. Bounded: a diff can hold hundreds of screenshots, each megabytes once decoded.
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        return cache
    }()
    private var unreadableImages: Set<String> = []
    private var loadingImages: Set<String> = []
    private static let imageRowCount = 14
    /// The rows VoiceOver asked for, by row: built on demand, dropped with the rows.
    private var accessibilityRows: [Int: ChangesAccessibilityElement] = [:]

    private struct Shaped {
        let line: CTLine
        /// The changed part of a replaced line, in UTF-16 offsets.
        let highlight: Range<Int>?
    }

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private let advance: CGFloat
    private let numberAdvance: CGFloat
    private let ascent: CGFloat
    private static let signWidth: CGFloat = 16
    /// Where a file header's path starts, past its chevron and status dot.
    private static let headerTextX: CGFloat = 40

    /// The terminal theme's colors, so a diff reads like `git diff` in a terminal tab.
    struct Palette {
        var background, text, secondary, numbers, separator, header, empty, hunk, selection: NSColor
        var added, removed, modified, renamed: NSColor
        var addedLine, removedLine, addedGutter, removedGutter, addedWord, removedWord: NSColor

        init(_ colors: TerminalTheme.Resolved) {
            // Opaque blends toward the background: each tint keeps the theme's hue at a set strength.
            let tint = { (color: VTColor, amount: Double) in color.mixed(with: colors.background, amount: amount).nsColor }
            let green = colors.palette[2], red = colors.palette[1]
            background = colors.background.nsColor
            text = colors.foreground.nsColor
            secondary = tint(colors.foreground, 0.4)
            numbers = tint(colors.foreground, 0.6)
            separator = tint(colors.foreground, 0.88)
            header = tint(colors.foreground, 0.95)
            empty = tint(colors.foreground, 0.97)
            hunk = tint(colors.palette[4], 0.94)
            selection = colors.selection.nsColor.withAlphaComponent(0.45)
            added = green.nsColor
            removed = red.nsColor
            modified = colors.palette[3].nsColor
            renamed = colors.palette[4].nsColor
            // A light line tint and a stronger gutter: the change reads from the numbers.
            addedLine = tint(green, 0.9)
            removedLine = tint(red, 0.9)
            addedGutter = tint(green, 0.72)
            removedGutter = tint(red, 0.72)
            addedWord = tint(green, 0.65)
            removedWord = tint(red, 0.65)
        }

        func status(_ status: GitDiff.Status) -> NSColor {
            switch status {
            case .modified: modified
            case .added: added
            case .deleted: removed
            case .renamed: renamed
            }
        }
    }

    /// Set by the terminal host whenever the theme or the surface under it changes.
    static var palette = Palette(TerminalTheme.auto.resolved(surface: VTColor(NSColor.textBackgroundColor), accent: VTColor(NSColor.controlAccentColor)))

    private static let maxCharacters = 2000
    /// Files with more diff lines than this, generated files and lock files start folded.
    private static let foldedLineCount = 1500

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        numberAdvance = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        ascent = font.ascender
        super.init(frame: .zero)
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 7
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Diff".localized)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Rows

    private func rebuild() {
        shapedLines = [:]
        accessibilityRows = [:]
        selection = nil
        rows = []
        fileRows = []
        guard let diff else {
            partners = []
            invalidateIntrinsicContentSize()
            needsDisplay = true
            return
        }
        partners = [Int32](repeating: -1, count: diff.lines.count)
        rows.reserveCapacity(diff.lines.count + diff.files.count * 3)
        var maxNumber: Int32 = 1
        widestLine = 0
        for (index, file) in diff.files.enumerated() {
            let fileIndex = Int32(index)
            if index > 0 { rows.append(Row(kind: .gap, file: fileIndex)) }
            fileRows.append(rows.count)
            rows.append(Row(kind: .file, file: fileIndex))
            if isFolded(file) {
                rows.append(Row(kind: .collapsed, file: fileIndex))
                continue
            }
            if file.isImage {
                rows.append(contentsOf: repeatElement(Row(kind: .image, file: fileIndex), count: Self.imageRowCount))
                continue
            }
            var line = file.lines.lowerBound
            while line < file.lines.upperBound {
                let record = diff.lines[line]
                maxNumber = max(maxNumber, record.oldNumber, record.newNumber)
                widestLine = max(widestLine, Int(record.length))
                switch record.kind {
                case .hunk:
                    rows.append(Row(kind: .hunk, file: fileIndex, left: Int32(line)))
                    line += 1
                case .context:
                    rows.append(Row(kind: .line, file: fileIndex, left: Int32(line), right: Int32(line)))
                    line += 1
                case .removed, .added:
                    // A block of removed lines then added ones: the nth of each replace one another.
                    var removedEnd = line
                    while removedEnd < file.lines.upperBound, diff.lines[removedEnd].kind == .removed { removedEnd += 1 }
                    var addedEnd = removedEnd
                    while addedEnd < file.lines.upperBound, diff.lines[addedEnd].kind == .added { addedEnd += 1 }
                    for changed in line..<addedEnd {
                        maxNumber = max(maxNumber, diff.lines[changed].oldNumber, diff.lines[changed].newNumber)
                        widestLine = max(widestLine, Int(diff.lines[changed].length))
                    }
                    let removedCount = removedEnd - line, addedCount = addedEnd - removedEnd
                    for offset in 0..<min(removedCount, addedCount) {
                        partners[line + offset] = Int32(removedEnd + offset)
                        partners[removedEnd + offset] = Int32(line + offset)
                    }
                    if isSplit {
                        for offset in 0..<max(removedCount, addedCount) {
                            rows.append(Row(
                                kind: .line, file: fileIndex,
                                left: offset < removedCount ? Int32(line + offset) : -1,
                                right: offset < addedCount ? Int32(removedEnd + offset) : -1
                            ))
                        }
                    } else {
                        for changed in line..<addedEnd { rows.append(Row(kind: .line, file: fileIndex, left: Int32(changed))) }
                    }
                    line = max(addedEnd, line + 1)
                }
            }
        }
        numberWidth = CGFloat(String(maxNumber).count) * numberAdvance + 18
        needsDisplay = true
    }

    func isFolded(_ file: GitDiff.File) -> Bool {
        (file.isBinary && !file.isImage) || isFoldedByDefault(file) != toggledPaths.contains(file.path)
    }

    private func isFoldedByDefault(_ file: GitDiff.File) -> Bool {
        let name = (file.path as NSString).lastPathComponent
        return file.status == .deleted || file.lines.count > Self.foldedLineCount || Self.isGenerated(file.path)
            || name.hasSuffix(".lock") || name.hasSuffix("-lock.json") || name.hasSuffix("-lock.yaml") || name == "Package.resolved"
    }

    private static func isGenerated(_ path: String) -> Bool {
        path.hasSuffix(".pbxproj") || path.contains(".gen.") || path.hasPrefix("Generated/") || path.contains("/Generated/")
    }

    /// Folds an unfolded file or unfolds a folded one; a binary file other than an image stays folded.
    func toggleFold(_ index: Int) {
        guard let file = diff?.files[index], !file.isBinary || file.isImage else { return }
        if toggledPaths.remove(file.path) == nil { toggledPaths.insert(file.path) }
        let anchor = anchor()
        rebuild()
        onRowsChange?()
        if let anchor { restore(anchor) }
    }

    /// Sizes the view: as tall as its rows, and as wide as its longest line when unified.
    func fit(toWidth width: CGFloat, height: CGFloat) {
        let textWidth = CGFloat(min(widestLine, Self.maxCharacters)) * advance
        let contentWidth = isSplit ? width : max(width, numberWidth + Self.signWidth + textWidth + 24)
        let size = NSSize(width: contentWidth, height: max(height, CGFloat(rows.count) * rowHeight + rowHeight))
        guard frame.size != size else { return }
        setFrameSize(size)
        // The rows built for VoiceOver span the former width.
        accessibilityRows = [:]
    }

    func fileIndex(atY y: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        let row = min(rows.count - 1, max(0, Int(y / rowHeight)))
        return Int(rows[row].file)
    }

    func scrollToFile(_ index: Int, animated: Bool = false) {
        guard index < fileRows.count else { return }
        let point = NSPoint(x: visibleRect.minX, y: CGFloat(fileRows[index]) * rowHeight)
        guard animated, let scrollView = enclosingScrollView else { return scroll(point) }
        let clip = scrollView.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = WindowFrameView.toggleTiming
            clip.animator().setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    func anchor() -> Anchor? {
        guard let diff, !rows.isEmpty else { return nil }
        let top = visibleRect.minY
        let row = min(rows.count - 1, Int(top / rowHeight))
        let file = Int(rows[row].file)
        return Anchor(path: diff.files[file].path, row: row - fileRows[file], offset: top - CGFloat(row) * rowHeight)
    }

    func restore(_ anchor: Anchor) {
        guard let diff, let file = diff.files.firstIndex(where: { $0.path == anchor.path }) else { return }
        let end = file + 1 < fileRows.count ? fileRows[file + 1] : rows.count
        let row = min(fileRows[file] + anchor.row, end - 1)
        scroll(NSPoint(x: visibleRect.minX, y: CGFloat(row) * rowHeight + anchor.offset))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Self.palette.background.setFill()
        dirtyRect.fill()
        guard let diff, !rows.isEmpty else { return }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let first = max(0, Int(dirtyRect.minY / rowHeight))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        var drawnImage: Int32 = -1
        for index in first...last {
            let rect = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
            if rows[index].kind == .image {
                // The block is drawn whole from its first row: the dirty rect clips the rest.
                guard rows[index].file != drawnImage else { continue }
                drawnImage = rows[index].file
                let top = CGFloat(fileRows[Int(drawnImage)] + 1) * rowHeight
                drawImages(Int(drawnImage), in: NSRect(x: 0, y: top, width: bounds.width, height: CGFloat(Self.imageRowCount) * rowHeight))
                continue
            }
            draw(rows[index], in: rect, diff: diff, context: context)
            if selection?.contains(index) == true {
                Self.palette.selection.setFill()
                rect.fill(using: .sourceOver)
            }
        }
    }

    private func draw(_ row: Row, in rect: NSRect, diff: GitDiff, context: CGContext) {
        switch row.kind {
        case .gap, .image:
            break
        case .file:
            drawFileHeader(Int(row.file), in: rect, context: context)
        case .collapsed:
            drawText(foldedText(diff.files[Int(row.file)]), font: font, color: Self.palette.numbers, at: NSPoint(x: Self.headerTextX, y: rect.minY), context: context)
        case .hunk:
            drawHunk(diff.lines[Int(row.left)], diff: diff, in: rect, context: context)
        case .line:
            if isSplit {
                let half = (bounds.width / 2).rounded()
                drawSide(row.left, diff: diff, in: NSRect(x: 0, y: rect.minY, width: half, height: rect.height), context: context, side: .removed)
                drawSide(row.right, diff: diff, in: NSRect(x: half, y: rect.minY, width: bounds.width - half, height: rect.height), context: context, side: .added)
                Self.palette.separator.setFill()
                NSRect(x: half, y: rect.minY, width: 1, height: rect.height).fill()
            } else {
                drawUnified(Int(row.left), diff: diff, in: rect, context: context)
            }
        }
    }

    private func foldedText(_ file: GitDiff.File) -> String {
        file.isBinary ? "Binary file, not shown".localized
            : Self.isGenerated(file.path) ? String(format: "Generated file, %d lines folded. Click to show.".localized, file.lines.count)
            : String(format: "%d lines folded. Click to show.".localized, file.lines.count)
    }

    /// A hairline across the diff, the hunk's range dimmed and the enclosing function, when git
    /// names one, in front.
    private func drawHunk(_ line: GitDiff.Line, diff: GitDiff, in rect: NSRect, context: CGContext) {
        Self.palette.hunk.setFill()
        rect.fill()
        Self.palette.separator.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        let text = displayText(line, diff: diff)
        var range = text, function = ""
        if let open = text.range(of: "@@"), let close = text.range(of: "@@", range: open.upperBound..<text.endIndex) {
            range = String(text[..<close.upperBound])
            function = text[close.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        let x = numberWidth + Self.signWidth
        drawText(range, font: numberFont, color: Self.palette.numbers, at: NSPoint(x: x, y: rect.minY + 1), context: context)
        guard !function.isEmpty else { return }
        let rangeWidth = CGFloat(range.count) * numberAdvance
        drawText(function, font: font, color: Self.palette.secondary, at: NSPoint(x: x + rangeWidth + 12, y: rect.minY), context: context)
    }

    /// One number column: the new line's, or the old one's for a removed line.
    private func drawUnified(_ index: Int, diff: GitDiff, in rect: NSRect, context: CGContext) {
        let line = diff.lines[index]
        fillBackground(for: line.kind, in: rect, gutter: numberWidth)
        drawNumber(line.kind == .removed ? line.oldNumber : line.newNumber, right: numberWidth - 8, y: rect.minY, context: context)
        drawLine(index, diff: diff, x: numberWidth, rect: rect, context: context)
    }

    /// One half of a split row: removed and context lines on the left, added and context on the right.
    private func drawSide(_ index: Int32, diff: GitDiff, in rect: NSRect, context: CGContext, side: GitDiff.LineKind) {
        guard index >= 0 else {
            Self.palette.empty.setFill()
            rect.fill()
            return
        }
        let line = diff.lines[Int(index)]
        context.saveGState()
        context.clip(to: rect)
        fillBackground(for: line.kind, in: rect, gutter: numberWidth)
        drawNumber(side == .removed ? line.oldNumber : line.newNumber, right: rect.minX + numberWidth - 8, y: rect.minY, context: context)
        drawLine(Int(index), diff: diff, x: rect.minX + numberWidth, rect: rect, context: context)
        context.restoreGState()
    }

    /// The line's tint, a stronger one under its numbers.
    private func fillBackground(for kind: GitDiff.LineKind, in rect: NSRect, gutter: CGFloat) {
        let line: NSColor, numbers: NSColor
        switch kind {
        case .added: (line, numbers) = (Self.palette.addedLine, Self.palette.addedGutter)
        case .removed: (line, numbers) = (Self.palette.removedLine, Self.palette.removedGutter)
        default: return
        }
        line.setFill()
        rect.fill()
        numbers.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: gutter, height: rect.height).fill()
    }

    /// The sign, the word highlight and the text of a line, from `x`.
    private func drawLine(_ index: Int, diff: GitDiff, x: CGFloat, rect: NSRect, context: CGContext) {
        let line = diff.lines[index]
        let sign: String
        let color: NSColor
        switch line.kind {
        case .added: (sign, color) = ("+", Self.palette.added)
        case .removed: (sign, color) = ("-", Self.palette.removed)
        default: (sign, color) = ("", Self.palette.text)
        }
        if !sign.isEmpty { drawText(sign, font: font, color: color, at: NSPoint(x: x + 4, y: rect.minY), context: context) }
        let textX = x + Self.signWidth
        let shaped = shape(index, diff: diff)
        if let highlight = shaped.highlight {
            let start = CTLineGetOffsetForStringIndex(shaped.line, highlight.lowerBound, nil)
            let end = CTLineGetOffsetForStringIndex(shaped.line, highlight.upperBound, nil)
            (line.kind == .added ? Self.palette.addedWord : Self.palette.removedWord).setFill()
            NSBezierPath(roundedRect: NSRect(x: textX + start - 1, y: rect.minY + 2, width: max(2, end - start) + 2, height: rect.height - 4), xRadius: 3, yRadius: 3).fill()
        }
        context.setFillColor(Self.palette.text.cgColor)
        context.textPosition = CGPoint(x: textX, y: rect.minY + 3.5 + ascent)
        CTLineDraw(shaped.line, context)
    }

    private func shape(_ index: Int, diff: GitDiff) -> Shaped {
        if let cached = shapedLines[index] { return cached }
        if shapedLines.count > 20_000 { shapedLines.removeAll(keepingCapacity: true) }
        let text = displayText(diff.lines[index], diff: diff)
        var highlight: Range<Int>?
        let partner = partners.isEmpty ? -1 : partners[index]
        if partner >= 0 {
            highlight = Self.changedRange(Array(text.utf16), Array(displayText(diff.lines[Int(partner)], diff: diff).utf16))
        }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            // The context's fill color draws the text: a shaped line survives an appearance change.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let result = Shaped(line: CTLineCreateWithAttributedString(attributed), highlight: highlight)
        shapedLines[index] = result
        return result
    }

    private func displayText(_ line: GitDiff.Line, diff: GitDiff) -> String {
        let bytes = diff.text(of: line).prefix(Self.maxCharacters)
        // Latin-1 decodes any bytes: a line from a file in another encoding still reads.
        var text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        if text.hasSuffix("\r") { text.removeLast() }
        if text.contains("\t") { text = text.replacingOccurrences(of: "\t", with: "    ") }
        return text
    }

    /// The part of `line` that differs from `other`, past their common start and end; nil when the
    /// lines share nothing, since the line color says it all then.
    nonisolated static func changedRange(_ line: [UInt16], _ other: [UInt16]) -> Range<Int>? {
        let limit = min(line.count, other.count)
        var prefix = 0
        while prefix < limit, line[prefix] == other[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, line[line.count - 1 - suffix] == other[other.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix > 0, prefix < line.count - suffix else { return nil }
        return prefix..<(line.count - suffix)
    }

    private func drawNumber(_ number: Int32, right: CGFloat, y: CGFloat, context: CGContext) {
        guard number > 0 else { return }
        let text = String(number)
        let width = CGFloat(text.count) * numberAdvance
        drawText(text, font: numberFont, color: Self.palette.numbers, at: NSPoint(x: right - width, y: y + 1.5), context: context)
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, at point: NSPoint, context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: Self.attributes(font, color)))
        context.textPosition = CGPoint(x: point.x, y: point.y + 3.5 + font.ascender)
        CTLineDraw(line, context)
    }

    /// Core Text reads its own color key, resolved here for the appearance being drawn.
    private static func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
    }

    /// A file's bar: its fold chevron, status dot, folder dimmed then name, former path when
    /// renamed, and counts. The sticky header draws it too.
    func drawFileHeader(_ index: Int, in rect: NSRect, context: CGContext) {
        guard let file = diff?.files[index] else { return }
        Self.palette.header.setFill()
        rect.fill()
        Self.palette.separator.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let chevron = isFolded(file) ? "chevron.right" : "chevron.down"
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(.init(paletteColors: [Self.palette.numbers]))
        if let image = NSImage(systemSymbolName: chevron, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let size = image.size
            image.draw(in: NSRect(x: rect.minX + 12 + (10 - size.width) / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        Self.palette.status(file.status).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 28, y: rect.midY - 3.5, width: 7, height: 7)).fill()

        let path = NSMutableAttributedString()
        let folder = (file.path as NSString).deletingLastPathComponent
        if !folder.isEmpty { path.append(NSAttributedString(string: folder + "/", attributes: Self.attributes(font, Self.palette.secondary))) }
        path.append(NSAttributedString(string: (file.path as NSString).lastPathComponent, attributes: Self.attributes(boldFont, Self.palette.text)))
        if let oldPath = file.oldPath {
            path.append(NSAttributedString(string: "  " + String(format: "renamed from %@".localized, oldPath), attributes: Self.attributes(font, Self.palette.numbers)))
        }
        let pathLine = CTLineCreateWithAttributedString(path)
        context.textPosition = CGPoint(x: rect.minX + Self.headerTextX, y: rect.minY + 3.5 + boldFont.ascender)
        CTLineDraw(pathLine, context)

        let counts = NSMutableAttributedString()
        if file.added > 0 { counts.append(NSAttributedString(string: "+\(file.added.formatted()) ", attributes: Self.attributes(boldFont, Self.palette.added))) }
        if file.removed > 0 { counts.append(NSAttributedString(string: "-\(file.removed.formatted())", attributes: Self.attributes(boldFont, Self.palette.removed))) }
        let line = CTLineCreateWithAttributedString(counts)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: rect.maxX - 14 - width, y: rect.minY + 3.5 + boldFont.ascender)
        CTLineDraw(line, context)
    }

    // MARK: Images

    /// The file's versions side by side, before then after, each fit in its half over a checkerboard
    /// that shows transparency, its pixel size and weight under it.
    private func drawImages(_ index: Int, in rect: NSRect) {
        guard let diff else { return }
        let file = diff.files[index]
        var panes: [(label: String, image: NSImage??)] = []
        if file.status != .added { panes.append(("Before".localized, version(of: file, old: true, in: diff))) }
        if file.status != .deleted { panes.append((file.status == .added ? "Added".localized : "After".localized, version(of: file, old: false, in: diff))) }
        let margin: CGFloat = 14, gap: CGFloat = 14, caption = rowHeight
        let width = (rect.width - margin * 2 - gap * CGFloat(panes.count - 1)) / CGFloat(max(1, panes.count))
        for (offset, pane) in panes.enumerated() {
            let frame = NSRect(x: rect.minX + margin + CGFloat(offset) * (width + gap), y: rect.minY + 8,
                               width: width, height: rect.height - 16 - caption)
            Self.palette.empty.setFill()
            frame.fill()
            var text = pane.label
            if case let image?? = pane.image {
                let pixels = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
                let scale = min(1, frame.width / max(1, pixels.width), frame.height / max(1, pixels.height))
                let size = NSSize(width: pixels.width * scale, height: pixels.height * scale)
                let target = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
                drawCheckerboard(in: target)
                image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                text += "  \(Int(pixels.width)) × \(Int(pixels.height))"
            } else if case .some(.none) = pane.image {
                text += "  " + "Cannot be shown".localized
            }
            Self.palette.separator.setStroke()
            NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
            if let context = NSGraphicsContext.current?.cgContext {
                drawText(text, font: font, color: Self.palette.numbers, at: NSPoint(x: frame.minX, y: frame.maxY + 2), context: context)
            }
        }
    }

    private func drawCheckerboard(in rect: NSRect) {
        let square: CGFloat = 8
        NSColor.white.setFill()
        rect.fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX + (Int((y - rect.minY) / square).isMultiple(of: 2) ? 0 : square)
            while x < rect.maxX {
                NSRect(x: x, y: y, width: square, height: square).fill()
                x += square * 2
            }
            y += square
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// A version of an image file: nil while it loads off the main thread, `.some(nil)` when it cannot be read.
    private func version(of file: GitDiff.File, old: Bool, in diff: GitDiff) -> NSImage?? {
        let key = old ? "\(diff.target ?? ""):\(file.oldPath ?? file.path)" : "worktree:\(file.path)"
        if let image = images.object(forKey: key as NSString) { return image }
        if unreadableImages.contains(key) { return .some(nil) }
        guard loadingImages.insert(key).inserted else { return nil }
        Task.detached(priority: .userInitiated) {
            let data = old ? diff.oldContent(of: file) : diff.newContent(of: file)
            await MainActor.run { [weak self] in
                guard let self else { return }
                loadingImages.remove(key)
                if let image = data.flatMap(NSImage.init(data:)) {
                    images.setObject(image, forKey: key as NSString)
                } else {
                    unreadableImages.insert(key)
                }
                needsDisplay = true
            }
        }
        return nil
    }

    // MARK: Accessibility

    /// The rows in view: a file's bar and a folded file are buttons that fold or unfold it, a line
    /// reads its side, number and text.
    override func accessibilityChildren() -> [Any]? {
        guard let diff, !rows.isEmpty else { return [] }
        let first = max(0, Int(visibleRect.minY / rowHeight)), last = min(rows.count - 1, Int(visibleRect.maxY / rowHeight))
        guard first <= last else { return [] }
        return (first...last).compactMap { index -> ChangesAccessibilityElement? in
            if let element = accessibilityRows[index] { return element }
            let row = rows[index]
            let file = diff.files[Int(row.file)]
            var frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
            let element: ChangesAccessibilityElement
            switch row.kind {
            case .gap:
                return nil
            case .file, .collapsed:
                element = ChangesAccessibilityElement { [weak self] in self?.toggleFold(Int(row.file)) }
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(row.kind == .file ? file.accessibilityLabel(fullPath: true) : foldedText(file))
                element.setAccessibilityExpanded(!isFolded(file))
            case .image:
                // One element for the block, from its first row.
                guard index == fileRows[Int(row.file)] + 1 else { return nil }
                frame.size.height = CGFloat(Self.imageRowCount) * rowHeight
                element = ChangesAccessibilityElement()
                element.setAccessibilityRole(.image)
                element.setAccessibilityLabel(file.path)
            case .hunk:
                element = ChangesAccessibilityElement()
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityValue(displayText(diff.lines[Int(row.left)], diff: diff))
            case .line:
                let sides = row.left == row.right || !isSplit ? [row.left] : [row.left, row.right]
                let text = sides.filter { $0 >= 0 }.map { side -> String in
                    let line = diff.lines[Int(side)]
                    let text = displayText(line, diff: diff)
                    switch line.kind {
                    case .added: return String(format: "Added line %d: %@".localized, Int(line.newNumber), text)
                    case .removed: return String(format: "Removed line %d: %@".localized, Int(line.oldNumber), text)
                    default: return String(format: "Line %d: %@".localized, Int(line.newNumber), text)
                    }
                }.joined(separator: ", ")
                element = ChangesAccessibilityElement()
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityValue(text)
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(frame)
            accessibilityRows[index] = element
            return element
        }
    }

    // MARK: Mouse and keyboard

    private func row(at event: NSEvent) -> Int {
        min(rows.count - 1, max(0, Int(convert(event.locationInWindow, from: nil).y / rowHeight)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard !rows.isEmpty else { return }
        let index = row(at: event)
        if rows[index].kind == .file || rows[index].kind == .collapsed {
            return toggleFold(Int(rows[index].file))
        }
        guard rows[index].kind != .image else { return }
        selectsNewSide = isSplit && convert(event.locationInWindow, from: nil).x >= (bounds.width / 2).rounded()
        selectionAnchor = index
        selection = index...index
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let selectionAnchor, !rows.isEmpty else { return }
        autoscroll(with: event)
        let index = row(at: event)
        selection = min(selectionAnchor, index)...max(selectionAnchor, index)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        selectionAnchor = nil
    }

    @objc func copy(_ sender: Any?) {
        guard let diff, let selection else { return }
        let text = selection.compactMap { index -> String? in
            let row = rows[index]
            switch row.kind {
            case .file: return diff.files[Int(row.file)].path
            case .line, .hunk:
                // One side only: a split row the selected side leaves empty adds no line.
                let line = selectsNewSide && row.kind == .line ? row.right : row.left
                guard line >= 0 else { return isSplit ? nil : "" }
                let bytes = diff.text(of: diff.lines[Int(line)])
                return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
            default: return nil
            }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard !rows.isEmpty else { return }
        selection = 0...(rows.count - 1)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let page = max(rowHeight, visibleRect.height - 2 * rowHeight)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers, event.keyCode) {
        case ("j", _) where flags.isEmpty: jumpFile(by: 1)
        case ("k", _) where flags.isEmpty: jumpFile(by: -1)
        case (_, 125): scrollBy(rowHeight * 3)          // down arrow
        case (_, 126): scrollBy(-rowHeight * 3)         // up arrow
        case (" ", _): scrollBy(flags.contains(.shift) ? -page : page)
        case (_, 121): scrollBy(page)                   // page down
        case (_, 116): scrollBy(-page)                  // page up
        case (_, 115): scroll(NSPoint(x: visibleRect.minX, y: 0))       // home
        case (_, 119): scroll(NSPoint(x: visibleRect.minX, y: bounds.height))   // end
        default: super.keyDown(with: event)
        }
    }

    private func scrollBy(_ delta: CGFloat) {
        scroll(NSPoint(x: visibleRect.minX, y: max(0, visibleRect.minY + delta)))
    }

    private func jumpFile(by step: Int) {
        guard !fileRows.isEmpty else { return }
        let top = Int((visibleRect.minY + 1) / rowHeight)
        let current = fileRows.lastIndex { $0 <= top } ?? 0
        let atStart = fileRows[current] == top
        let target = step > 0 ? current + 1 : (atStart ? current - 1 : current)
        scrollToFile(min(fileRows.count - 1, max(0, target)), animated: true)
    }
}

/// The bar of the file at the top of the diff, held in place while its lines scroll under it.
@MainActor
final class ChangesStickyHeader: NSView {
    weak var diffView: ChangesDiffView?
    var file: Int? {
        didSet { if file != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let file, let context = NSGraphicsContext.current?.cgContext else { return }
        diffView?.drawFileHeader(file, in: bounds, context: context)
    }

    override func mouseDown(with event: NSEvent) {
        _ = accessibilityPerformPress()
    }

    /// Folds the file and brings its bar back in place, as a click on the bar itself does.
    override func accessibilityPerformPress() -> Bool {
        guard let file, let diffView else { return false }
        diffView.toggleFold(file)
        diffView.scrollToFile(file)
        return true
    }

    override func isAccessibilityElement() -> Bool { file != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        guard let file, let diff = diffView?.diff else { return nil }
        return diff.files[file].accessibilityLabel(fullPath: true)
    }
    override func isAccessibilityExpanded() -> Bool {
        guard let file, let diffView, let diff = diffView.diff else { return false }
        return !diffView.isFolded(diff.files[file])
    }
}

extension GitDiff.File {
    /// What VoiceOver reads for the file: its path or name, what happened to it and its counts.
    func accessibilityLabel(fullPath: Bool) -> String {
        var parts = [fullPath ? path : (path as NSString).lastPathComponent]
        switch status {
        case .modified: parts.append("Modified".localized)
        case .added: parts.append("New File".localized)
        case .deleted: parts.append("Deleted".localized)
        case .renamed: parts.append(oldPath.map { String(format: "renamed from %@".localized, $0) } ?? "Renamed".localized)
        }
        parts.append(String(format: "%d added, %d removed".localized, added, removed))
        return parts.joined(separator: ", ")
    }
}

/// A part of a drawn view that VoiceOver reads as its own element; pressing it runs `press`.
@MainActor
final class ChangesAccessibilityElement: NSAccessibilityElement {
    private let press: (@MainActor () -> Void)?

    init(press: (@MainActor () -> Void)? = nil) {
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        MainActor.assumeIsolated(press)
        return true
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        selector == #selector(accessibilityPerformPress) ? press != nil : super.isAccessibilitySelectorAllowed(selector)
    }
}

// MARK: - Header and list

/// The header and file list colors, matching the sidebar's changes chip rather than the terminal
/// theme: they sit on the window's frame, whatever the terminal looks like.
@MainActor
private enum ChangesColors {
    static let added = adaptive(light: 0x15803D, dark: 0x86EFAC)
    static let removed = adaptive(light: 0xB42318, dark: 0xFCA5A5)
    static let modified = adaptive(light: 0xB45309, dark: 0xFCD34D)
    static let renamed = adaptive(light: 0x6D28D9, dark: 0xC4B5FD)
    static let chip = NSColor(name: nil) { isDark($0) ? NSColor.black.withAlphaComponent(0.32) : NSColor.white.withAlphaComponent(0.6) }
    static let track = NSColor(name: nil) { isDark($0) ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06) }
    /// A raised segment or selected row, over the track or the list card.
    static let raised = NSColor(name: nil) { isDark($0) ? NSColor.white.withAlphaComponent(0.14) : .white }
    static let neutral = NSColor(name: nil) { isDark($0) ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.1) }

    static func status(_ status: GitDiff.Status) -> NSColor {
        switch status {
        case .modified: modified
        case .added: added
        case .deleted: removed
        case .renamed: renamed
        }
    }

    private nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        let color = { (hex: UInt32) in
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { isDark($0) ? color(dark) : color(light) }
    }
}

/// Lilo's segmented pill: a tinted track, the selected segment raised on it.
@MainActor
private final class ChangesSegmentedControl: NSView {
    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let height: CGFloat = 24
    private static let inset: CGFloat = 2
    private static let padding: CGFloat = 10

    var selectedSegment = 0 {
        didSet {
            guard selectedSegment != oldValue else { return }
            needsDisplay = true
            for (index, segment) in (segments ?? []).enumerated() {
                segment.setAccessibilityValue(index == selectedSegment)
                if index == selectedSegment { NSAccessibility.post(element: segment, notification: .valueChanged) }
            }
        }
    }
    var onChange: (() -> Void)?
    private let labels: [String]
    private let widths: [CGFloat]
    /// The segments as radio buttons, built the first time VoiceOver asks.
    private var segments: [ChangesAccessibilityElement]?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: widths.reduce(2 * Self.inset, +), height: Self.height)
    }

    init(labels: [String]) {
        self.labels = labels
        widths = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: Self.font]).width) + 2 * Self.padding }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func segmentRect(_ index: Int) -> NSRect {
        let x = widths[..<index].reduce(Self.inset, +)
        return NSRect(x: x, y: Self.inset, width: widths[index], height: bounds.height - 2 * Self.inset)
    }

    override func draw(_ dirtyRect: NSRect) {
        ChangesColors.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        ChangesColors.raised.setFill()
        NSBezierPath(roundedRect: segmentRect(selectedSegment), xRadius: 5, yRadius: 5).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (index, label) in labels.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: index == selectedSegment ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            let rect = segmentRect(index)
            (label as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: (rect.midY - size.height / 2).rounded()), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let index = labels.indices.first(where: { segmentRect($0).maxX >= x }) else { return }
        select(index)
    }

    private func select(_ index: Int) {
        guard index != selectedSegment else { return }
        selectedSegment = index
        onChange?()
    }

    override func accessibilityChildren() -> [Any]? {
        let segments = self.segments ?? labels.indices.map { index in
            let segment = ChangesAccessibilityElement { [weak self] in self?.select(index) }
            segment.setAccessibilityRole(.radioButton)
            segment.setAccessibilityLabel(labels[index])
            segment.setAccessibilityValue(index == selectedSegment)
            segment.setAccessibilityParent(self)
            return segment
        }
        self.segments = segments
        for (index, segment) in segments.enumerated() { segment.setAccessibilityFrameInParentSpace(segmentRect(index)) }
        return segments
    }
}

/// The added and removed counts, in the same chip as the sidebar's.
@MainActor
private final class ChangesCountsChip: NSView {
    private var text = NSAttributedString()

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let size = text.size()
        return NSSize(width: ceil(size.width) + 10, height: 17)
    }

    func set(added: Int, removed: Int) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let value = NSMutableAttributedString()
        value.append(NSAttributedString(string: "+\(added.formatted())", attributes: [.font: font, .foregroundColor: ChangesColors.added]))
        value.append(NSAttributedString(string: " -\(removed.formatted())", attributes: [.font: font, .foregroundColor: ChangesColors.removed]))
        text = value
        invalidateIntrinsicContentSize()
        needsDisplay = true
        superview?.needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ChangesColors.chip.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let size = text.size()
        text.draw(at: NSPoint(x: 5, y: ((bounds.height - size.height) / 2).rounded()))
    }
}

/// A list row whose selection is a raised card, as the sidebar's active tab.
private final class ChangesListRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("changesRow")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        ChangesColors.raised.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A row of the file list: a folder with its chevron and file count, or a file with its status
/// dot, name, counts and a five-block bar of their proportion.
private final class ChangesListCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("changesCell")
    private static let blocks = 5
    private static let blockSize: CGFloat = 6
    private static let blockGap: CGFloat = 2

    enum Content {
        case folder(String, count: Int, collapsed: Bool)
        case file(GitDiff.File)
    }

    var content: Content = .folder("", count: 0, collapsed: false) {
        didSet {
            if case let .file(file) = content { toolTip = file.path } else { toolTip = nil }
            needsDisplay = true
        }
    }
    /// Folds or unfolds a folder row.
    var onToggle: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func isAccessibilityElement() -> Bool { true }

    /// A folder reads as a button that folds it, a file as text: selecting its row shows its diff.
    override func accessibilityRole() -> NSAccessibility.Role? {
        if case .folder = content { return .button }
        return .staticText
    }

    override func accessibilityLabel() -> String? {
        guard case let .folder(path, count, _) = content else { return nil }
        return path + ", " + (count == 1 ? "1 file".localized : String(format: "%@ files".localized, count.formatted()))
    }

    override func accessibilityValue() -> Any? {
        guard case let .file(file) = content else { return nil }
        return file.accessibilityLabel(fullPath: false)
    }

    override func isAccessibilityExpanded() -> Bool {
        guard case let .folder(_, _, collapsed) = content else { return false }
        return !collapsed
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return onToggle != nil
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        selector == #selector(accessibilityPerformPress) ? onToggle != nil : super.isAccessibilitySelectorAllowed(selector)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case let .folder(path, count, collapsed):
            drawFolder(path, count: count, collapsed: collapsed)
        case let .file(file):
            drawFile(file)
        }
    }

    private func drawFolder(_ path: String, count: Int, collapsed: Bool) {
        // Text sits on the row's bottom: a taller row than a file's leaves the space above it.
        let baseline = bounds.height - 22
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.tertiaryLabelColor]))
        if let image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let size = image.size
            image.draw(in: NSRect(x: 14 + (8 - size.width) / 2, y: baseline + 11 - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let countText = NSAttributedString(string: count.formatted(), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor
        ])
        let countWidth = ceil(countText.size().width)
        countText.draw(at: NSPoint(x: bounds.width - 14 - countWidth, y: baseline + 4))
        let paragraph = NSMutableParagraphStyle()
        // The deepest folders tell folders apart: a long path keeps its end.
        paragraph.lineBreakMode = .byTruncatingHead
        NSAttributedString(string: path, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
        ]).draw(with: NSRect(x: 28, y: baseline + 4, width: max(0, bounds.width - 28 - countWidth - 22), height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawFile(_ file: GitDiff.File) {
        let midY = bounds.midY
        ChangesColors.status(file.status).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: midY - 3, width: 6, height: 6)).fill()

        // Five blocks split between additions and removals, as a pull request's file list shows them.
        let total = file.added + file.removed
        let green = total == 0 ? 0 : min(Self.blocks, Int((Double(file.added) / Double(total) * Double(Self.blocks)).rounded()))
        let red = total == 0 ? 0 : Self.blocks - green
        let barWidth = CGFloat(Self.blocks) * Self.blockSize + CGFloat(Self.blocks - 1) * Self.blockGap
        var x = bounds.width - 14 - barWidth
        for block in 0..<Self.blocks {
            (block < green ? ChangesColors.added : block < green + red ? ChangesColors.removed : ChangesColors.neutral).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - Self.blockSize / 2, width: Self.blockSize, height: Self.blockSize), xRadius: 1.5, yRadius: 1.5).fill()
            x += Self.blockSize + Self.blockGap
        }

        let numbers = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        let counts = NSMutableAttributedString()
        if file.added > 0 { counts.append(NSAttributedString(string: "+\(file.added.formatted())", attributes: [.font: numbers, .foregroundColor: ChangesColors.added])) }
        if file.removed > 0 {
            counts.append(NSAttributedString(string: (counts.length > 0 ? " " : "") + "-\(file.removed.formatted())", attributes: [.font: numbers, .foregroundColor: ChangesColors.removed]))
        }
        let countsSize = counts.size()
        let countsX = bounds.width - 14 - barWidth - 8 - ceil(countsSize.width)
        counts.draw(at: NSPoint(x: countsX, y: (midY - countsSize.height / 2).rounded()))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: (file.path as NSString).lastPathComponent, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: file.status == .deleted ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .strikethroughStyle: file.status == .deleted ? NSUnderlineStyle.single.rawValue : 0,
            .paragraphStyle: paragraph
        ])
        let nameHeight = name.size().height
        name.draw(with: NSRect(x: 30, y: (midY - nameHeight / 2).rounded(), width: max(0, countsX - 30 - 8), height: nameHeight + 2),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// Watches a repository's files with FSEvents, filtering them on a private queue, and calls back
/// on the main thread once a burst of relevant changes settles. Git's own bookkeeping counts only
/// when it moves HEAD, a ref or the index, which a linked worktree keeps outside its folder.
final class RepositoryWatcher {
    private let stream: FSEventStreamRef

    /// What the queue reads; the stream retains it, so a callback still running outlives the watcher.
    private final class Filter: @unchecked Sendable {
        let queue = DispatchQueue(label: "fr.arouillard.lilo.changes.watcher", qos: .utility)
        let onChange: @MainActor @Sendable () -> Void
        /// Real paths with a trailing slash, as FSEvents reports them: the git directories, and the
        /// linked worktrees nested in the watched folder, whose edits are theirs.
        let own: String
        let common: String
        let nested: [String]
        let root: String
        /// The gitignored folders under the root; `queue` only, empty until the first read.
        var ignored: [String] = []

        init(own: String, common: String, nested: [String], root: String, onChange: @escaping @MainActor @Sendable () -> Void) {
            self.own = own
            self.common = common
            self.nested = nested
            self.root = root
            self.onChange = onChange
        }

        /// Lists the gitignored folders on `queue`, so the events behind it wait for the list.
        func readIgnored() {
            // Only whole folders: a build or package folder is where the noise comes from.
            guard let output = GitDiff.run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: root) else { return }
            ignored = output.split(separator: 0).filter { $0.last == UInt8(ascii: "/") }
                .compactMap { String(bytes: $0, encoding: .utf8).map { root + $0 } }
        }

        func matters(_ path: String) -> Bool {
            if path.hasPrefix(own) {
                let inside = path.dropFirst(own.count)
                if inside == "index" || inside == "HEAD" { return true }
            }
            if path.hasPrefix(common) {
                let inside = path.dropFirst(common.count)
                return inside == "packed-refs" || inside.hasPrefix("refs/")
            }
            return !path.contains("/.git/") && !nested.contains(where: path.hasPrefix) && !ignored.contains(where: path.hasPrefix)
        }
    }

    init?(root: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        let real = { (path: String) -> String in
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let directories = GitDiff.gitDirectories(of: root)
        let root = real(root) + "/"
        let common = real(directories.common) + "/"
        let own = real(directories.own) + "/"
        let worktrees = (try? FileManager.default.contentsOfDirectory(atPath: common + "worktrees")) ?? []
        let nested = worktrees.compactMap { name -> String? in
            // Each names its worktree's .git file.
            guard let link = try? String(contentsOfFile: common + "worktrees/\(name)/gitdir", encoding: .utf8) else { return nil }
            let folder = real((link.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).deletingLastPathComponent) + "/"
            return folder.hasPrefix(root) && folder != root ? folder : nil
        }
        var watched = [root]
        for directory in [common, own] where !watched.contains(where: directory.hasPrefix) {
            watched.append(directory)
        }
        let filter = Filter(own: own, common: common, nested: nested, root: root, onChange: onChange)

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(filter).toOpaque(),
            retain: { info in info.map { UnsafeRawPointer(Unmanaged<Filter>.fromOpaque($0).retain().toOpaque()) } },
            release: { info in info.map { Unmanaged<Filter>.fromOpaque($0).release() } },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let filter = Unmanaged<Filter>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            // A folder created outside the known ignored ones (a first .build/) may be ignored too.
            let createdFolder = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
            let newFolder = paths.indices.prefix(count).contains { index in
                flags[index] & createdFolder == createdFolder && !paths[index].hasPrefix(filter.common) && filter.matters(paths[index])
            }
            if newFolder { filter.readIgnored() }
            let relevant = paths.prefix(count).contains(where: filter.matters)
            PerfSignposts.energy.emitEvent("changesEvent", "\(relevant ? "relevant" : "ignored")")
            guard relevant else { return }
            let onChange = filter.onChange
            DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, watched as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, filter.queue)
        FSEventStreamStart(stream)
        filter.queue.async { filter.readIgnored() }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
