import XCTest
@testable import Lilo

final class GitDiffTests: XCTestCase {
    private var repository: URL!

    override func setUpWithError() throws {
        repository = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try write("Sources/app.swift", "let a = 1\nlet b = 2\nlet c = 3\n")
        try write("old.txt", "keep\n")
        try write("gone.txt", "bye\n")
        try git("add", ".")
        try git("-c", "user.name=Lilo", "-c", "user.email=lilo@example.com", "commit", "-q", "-m", "initial")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repository)
    }

    func testUncommittedChangesListEveryFileWithItsLines() throws {
        try write("Sources/app.swift", "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4\n")
        try FileManager.default.removeItem(at: repository.appendingPathComponent("gone.txt"))
        try git("mv", "old.txt", "renamed.txt")
        try write("notes/new.md", "one\ntwo\n")

        let diff = try XCTUnwrap(GitDiff.load(in: repository.path, mode: .uncommitted))
        let byPath = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })

        let app = try XCTUnwrap(byPath["Sources/app.swift"])
        XCTAssertEqual(app.status, .modified)
        XCTAssertEqual(app.added, 2)
        XCTAssertEqual(app.removed, 1)
        let lines = diff.lines[app.lines]
        XCTAssertEqual(lines.first?.kind, .hunk)
        let removed = try XCTUnwrap(lines.first { $0.kind == .removed })
        XCTAssertEqual(String(decoding: diff.text(of: removed), as: UTF8.self), "let b = 2")
        XCTAssertEqual(removed.oldNumber, 2)
        let added = lines.filter { $0.kind == .added }
        XCTAssertEqual(added.map { String(decoding: diff.text(of: $0), as: UTF8.self) }, ["let b = 20", "let d = 4"])
        XCTAssertEqual(added.map(\.newNumber), [2, 4])

        XCTAssertEqual(byPath["gone.txt"]?.status, .deleted)
        XCTAssertEqual(byPath["renamed.txt"]?.status, .renamed)
        XCTAssertEqual(byPath["renamed.txt"]?.oldPath, "old.txt")

        let untracked = try XCTUnwrap(byPath["notes/new.md"])
        XCTAssertEqual(untracked.status, .added)
        XCTAssertEqual(diff.lines[untracked.lines].map { String(decoding: diff.text(of: $0), as: UTF8.self) }, ["one", "two"])

        XCTAssertEqual(diff.added, 4)
        XCTAssertEqual(diff.removed, 2)
    }

    func testAnImageIsReadInBothVersionsFromTheRoot() throws {
        let before = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2]), after = Data([0x89, 0x50, 0x4E, 0x47, 0, 3, 4])
        let image = repository.appendingPathComponent("docs/shot.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try before.write(to: image)
        try git("add", ".")
        try git("-c", "user.name=Lilo", "-c", "user.email=lilo@example.com", "commit", "-q", "-m", "image")
        try after.write(to: image)
        try Data([0x47, 0x49, 0x46, 0]).write(to: repository.appendingPathComponent("docs/new.gif"))

        // From a subfolder: a version is still read at the repository's root.
        let diff = try XCTUnwrap(GitDiff.load(in: repository.appendingPathComponent("docs").path, mode: .uncommitted))
        let byPath = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })

        let shot = try XCTUnwrap(byPath["docs/shot.png"])
        XCTAssertTrue(shot.isImage)
        XCTAssertEqual(diff.oldContent(of: shot), before)
        XCTAssertEqual(diff.newContent(of: shot), after)
        let added = try XCTUnwrap(byPath["docs/new.gif"])
        XCTAssertTrue(added.isImage)
        XCTAssertNil(diff.oldContent(of: added))
        XCTAssertFalse(GitDiff.File(path: "archive.zip", isBinary: true).isImage, "only an image takes a preview")
    }

    func testABinaryFileKeepsAPathHoldingABSlashOrAQuote() throws {
        let paths = ["a b/x.png", "say \"hi\".png"]
        for path in paths {
            let url = repository.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47, 0, 1]).write(to: url)
        }
        try git("add", ".")
        try git("-c", "user.name=Lilo", "-c", "user.email=lilo@example.com", "commit", "-q", "-m", "images")
        for path in paths { try Data([0x89, 0x50, 0x4E, 0x47, 0, 2]).write(to: repository.appendingPathComponent(path)) }

        let diff = try XCTUnwrap(GitDiff.load(in: repository.path, mode: .uncommitted))

        XCTAssertEqual(Set(diff.files.map(\.path)), Set(paths))
    }

    func testStatCountsUntrackedLinesAndFollowsTheRepositoryFromASubfolder() throws {
        try write("Sources/app.swift", "let a = 1\nlet c = 3\n")
        try write("new.txt", "x\ny\nz")

        let stat = try XCTUnwrap(GitDiff.stat(in: repository.appendingPathComponent("Sources").path))
        XCTAssertEqual(stat.added, 3)
        XCTAssertEqual(stat.removed, 1)
    }

    func testAnEmptyUntrackedFileAddsNoLine() throws {
        try write("empty.txt", "")

        XCTAssertEqual(GitDiff.stat(in: repository.path)?.added, 0)
        XCTAssertEqual(GitDiff.load(in: repository.path, mode: .uncommitted)?.files.first { $0.path == "empty.txt" }?.added, 0)
    }

    func testBranchModeComparesWithTheMergeBaseAndKeepsUncommittedWork() throws {
        try git("checkout", "-q", "-b", "feature")
        try write("feature.txt", "committed\n")
        try git("add", ".")
        try git("-c", "user.name=Lilo", "-c", "user.email=lilo@example.com", "commit", "-q", "-m", "feature")
        try write("Sources/app.swift", "let a = 1\n")

        let diff = try XCTUnwrap(GitDiff.load(in: repository.path, mode: .branch))
        XCTAssertEqual(diff.base, "main")
        XCTAssertEqual(diff.mergeBase?.count, 7)
        XCTAssertEqual(Set(diff.files.map(\.path)), ["feature.txt", "Sources/app.swift"])
    }

    func testCleanTreeHasNoFiles() throws {
        let diff = try XCTUnwrap(GitDiff.load(in: repository.path, mode: .uncommitted))
        XCTAssertTrue(diff.files.isEmpty)
        XCTAssertEqual(GitDiff.stat(in: repository.path)?.added, 0)
    }

    func testChangedRangeSkipsTheCommonStartAndEnd() {
        XCTAssertEqual(ChangesDiffView.changedRange(Array("let b = 20".utf16), Array("let b = 2".utf16)), 9..<10)
        XCTAssertNil(ChangesDiffView.changedRange(Array("abc".utf16), Array("xyz".utf16)))
    }

    func testWorktreesListTheMainOneFirstAndSkipThoseWhoseFolderIsGone() throws {
        let worktree = repository.appendingPathExtension("wt")
        let gone = repository.appendingPathExtension("gone")
        defer { try? FileManager.default.removeItem(at: worktree) }
        try git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try git("worktree", "add", "-q", "-b", "other", gone.path)
        try FileManager.default.removeItem(at: gone)

        let real = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(GitDiff.worktrees(of: worktree.path).map(real), [real(repository.path), real(worktree.path)])
    }

    func testLinkedWorktreeLoadsItsOwnChanges() throws {
        let worktree = repository.appendingPathExtension("wt")
        defer { try? FileManager.default.removeItem(at: worktree) }
        try git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try "let a = 10\nlet b = 2\nlet c = 3\n".write(to: worktree.appendingPathComponent("Sources/app.swift"), atomically: true, encoding: .utf8)

        let diff = try XCTUnwrap(GitDiff.load(in: worktree.appendingPathComponent("Sources").path, mode: .uncommitted))
        XCTAssertEqual(diff.files.map(\.path), ["Sources/app.swift"])
        XCTAssertEqual(GitDiff.repositoryRoot(containing: worktree.appendingPathComponent("Sources").path), worktree.path)
        let directories = GitDiff.gitDirectories(of: worktree.path)
        let real = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(real(directories.common), real(repository.appendingPathComponent(".git").path))
        XCTAssertEqual(real(directories.own), real(repository.appendingPathComponent(".git/worktrees/\(worktree.lastPathComponent)").path))
    }

    func testNestedWorktreeIsNotAnUntrackedFile() throws {
        try git("worktree", "add", "-q", "-b", "feature", repository.appendingPathComponent("nested/wt").path)

        let diff = try XCTUnwrap(GitDiff.load(in: repository.path, mode: .uncommitted))
        XCTAssertEqual(diff.files.map(\.path), [])
    }

    func testWatcherSeesStagingInALinkedWorktree() throws {
        let worktree = repository.appendingPathExtension("wt")
        defer { try? FileManager.default.removeItem(at: worktree) }
        try git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try "changed\n".write(to: worktree.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)

        let staged = expectation(description: "staging reloads")
        staged.assertForOverFulfill = false
        let watcher = try XCTUnwrap(RepositoryWatcher(root: worktree.path) { staged.fulfill() })
        try git("add", "old.txt", in: worktree)
        // The watcher runs git on a utility queue to list the ignored folders, at start and on a new folder, ahead of
        // the events behind them: a busy machine holds that queue and its git back for seconds.
        wait(for: [staged], timeout: 30)
        withExtendedLifetime(watcher) {}
    }

    func testWatcherStaysQuietForWritesInIgnoredFolders() throws {
        try write(".gitignore", "build/\n")
        try write("build/first.o", "x\n")
        // fseventsd can hand a new stream writes made before it started, the setup's. A recorder started first hears
        // all the watcher does: a reload while it heard more than the ignored write proves nothing, so try again.
        for attempt in 1...5 {
            let recorder = try FSEventRecorder(watching: repository)
            let quiet = XCTestExpectation(description: "an ignored write reloads nothing")
            quiet.isInverted = true
            let watcher = try XCTUnwrap(RepositoryWatcher(root: repository.path) { quiet.fulfill() })
            let ignored = "build/\(attempt).o"
            try write(ignored, "y\n")
            let result = XCTWaiter().wait(for: [quiet], timeout: 3)
            withExtendedLifetime(watcher) {}
            if result == .completed { return }
            let others = recorder.paths().filter { !$0.hasSuffix("/" + ignored) }
            if others.isEmpty { return XCTFail("the ignored write alone reloaded") }
        }
        XCTFail("the setup's writes still reached every watcher")
    }

    @MainActor
    func testTerminalLineCountsRunOncePerIntervalButFollowADirectoryChangeAtOnce() async throws {
        let session = TerminalSession(cwd: repository.path, command: ["/bin/cat"])
        try session.start()
        defer { session.terminate() }
        let enter = { (path: String) in
            Array("\u{1B}]7;file://localhost\(path)\u{07}".utf8).withUnsafeBytes { bytes in session.withLockedTerminal { $0.write(bytes) } }
        }
        // The first count runs after this, so the deferred one cannot land before start + 5 s.
        let start = Date()
        enter(repository.path)
        let counted = await pollUntil(timeout: 20) { session.status.gitBranch == "main" }
        XCTAssertTrue(counted)

        try write("old.txt", "keep\nmore\n")
        session.refreshGitBranch(withStat: true)
        let early = await pollUntil(timeout: max(0, 4 - Date().timeIntervalSince(start))) { session.status.diffAdded != 0 }
        XCTAssertFalse(early, "a second count within the interval waits for its end")
        let deferred = await pollUntil(timeout: 20) { session.status.diffAdded == 1 }
        XCTAssertTrue(deferred, "the waiting count runs at the end of the interval")

        // That count opened a new interval: one within 3 s comes from the move.
        try write("old.txt", "keep\nmore\nagain\n")
        enter(repository.appendingPathComponent("Sources").path)
        let followed = await pollUntil(timeout: 3) { session.status.diffAdded == 2 }
        XCTAssertTrue(followed, "a new directory is counted at once")
    }

    @MainActor
    func testAReloadThatFindsNothingNewKeepsTheShownDiff() async throws {
        try write("old.txt", "keep\nmore\n")
        let view = ChangesView(directory: repository.path)
        // A rebuild installs the freshly loaded diff, whose bytes live in a new buffer.
        let shownBuffer = { view.diffView.diff?.bytes.withUnsafeBufferPointer { $0.baseAddress } }
        // No hook reports a finished load, so the test reads the view's own flags.
        let idle = {
            let mirror = Mirror(reflecting: view)
            return mirror.descendant("isLoading") as? Bool == false && mirror.descendant("reloadAgain") as? Bool == false
        }
        view.reload()
        let loaded = await pollUntil(timeout: 20) { idle() && view.diffView.diff != nil }
        XCTAssertTrue(loaded)
        let shown = shownBuffer()

        view.reload()
        let reloaded = await pollUntil(timeout: 20) { idle() }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(shownBuffer(), shown, "an unchanged reload leaves the view alone")

        try write("old.txt", "keep\nmore\nagain\n")
        view.reload()
        let rebuilt = await pollUntil(timeout: 20) { shownBuffer() != shown }
        XCTAssertTrue(rebuilt, "a changed reload shows the new diff")
    }

    @MainActor
    func testAReloadAskedDuringALoadWaitsAGapAfterIt() async throws {
        let view = ChangesView(directory: repository.path)
        let state = { (name: String) in Mirror(reflecting: view).descendant(name) }
        view.reload()
        view.reload()
        let waiting = await pollUntil(timeout: 20) { state("isLoading") as? Bool == false && state("followUp") is DispatchWorkItem }
        XCTAssertTrue(waiting, "the second request waits once the first load ends")
        let ended = Date()

        let idle = await pollUntil(timeout: 20) {
            state("isLoading") as? Bool == false && state("followUp") as? DispatchWorkItem == nil && state("reloadAgain") as? Bool == false
        }
        XCTAssertTrue(idle)
        XCTAssertGreaterThan(Date().timeIntervalSince(ended), 1.5, "the follow-up starts a gap after the load")
    }

    @MainActor
    func testVoiceOverReadsTheDrawnControlsListAndDiff() async throws {
        try write("old.txt", "keep\nmore\n")
        let view = ChangesView(directory: repository.path)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(view)
        view.reload()
        let loaded = await pollUntil(timeout: 20) { view.diffView.diff != nil }
        XCTAssertTrue(loaded)
        view.layoutSubtreeIfNeeded()
        // Every element under `root`, VoiceOver's way down.
        func elements(_ root: NSAccessibilityProtocol) -> [NSAccessibilityProtocol] {
            (root.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }.flatMap { [$0] + elements($0) }
        }

        let layout = try XCTUnwrap(elements(view).first { $0.accessibilityRole() == .radioGroup && $0.accessibilityLabel() == "Diff Layout".localized })
        let segments = elements(layout)
        XCTAssertEqual(segments.map { $0.accessibilityRole() }, [.radioButton, .radioButton])
        XCTAssertEqual(segments.map { $0.accessibilityLabel() }, ["Unified".localized, "Split".localized])
        XCTAssertEqual(segments.map { $0.accessibilityValue() as? Bool }, [true, false])

        let file = "old.txt, " + "Modified".localized + ", " + String(format: "%d added, %d removed".localized, 1, 0)
        func tables(_ root: NSView) -> [NSTableView] { root.subviews.flatMap { ($0 as? NSTableView).map { [$0] } ?? tables($0) } }
        let list = try XCTUnwrap(tables(view).first)
        let cells = (0..<list.numberOfRows).compactMap { list.view(atColumn: 0, row: $0, makeIfNecessary: true) }
        XCTAssertTrue(cells.contains { $0.accessibilityRole() == .staticText && $0.accessibilityValue() as? String == file }, "the list names the file")
        let line = String(format: "Added line %d: %@".localized, 2, "more")
        XCTAssertTrue(elements(view.diffView).contains { $0.accessibilityValue() as? String == line }, "the diff reads its lines")
        let bar = try XCTUnwrap(elements(view.diffView).first { $0.accessibilityRole() == .button })
        XCTAssertEqual(bar.accessibilityLabel(), file)
        XCTAssertTrue(bar.isAccessibilityExpanded())

        XCTAssertTrue(bar.accessibilityPerformPress())
        XCTAssertFalse(try XCTUnwrap(elements(view.diffView).first { $0.accessibilityRole() == .button }).isAccessibilityExpanded(), "pressing the bar folds the file")

        XCTAssertTrue(segments[1].accessibilityPerformPress())
        XCTAssertTrue(view.diffView.isSplit)
        XCTAssertEqual(segments.map { $0.accessibilityValue() as? Bool }, [false, true])
    }

    private func write(_ path: String, _ content: String) throws {
        let url = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: String..., in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? repository
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}

/// Every path fseventsd reports under a folder from now on, file by file.
private final class FSEventRecorder {
    /// What the stream's queue appends to; the stream holds it unretained, so it lives as long as the recorder.
    private final class Heard {
        let lock = NSLock()
        var paths: [String] = []
    }

    private let stream: FSEventStreamRef
    private let heard = Heard()

    init(watching folder: URL) throws {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(heard).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        stream = try XCTUnwrap(FSEventStreamCreate(
            nil, { _, info, count, paths, _, _ in
                guard let info, let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
                let heard = Unmanaged<Heard>.fromOpaque(info).takeUnretainedValue()
                heard.lock.withLock { heard.paths += paths.prefix(count) }
            },
            &context, [folder.resolvingSymlinksInPath().path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ))
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "fr.arouillard.lilo.tests.fsevents"))
        FSEventStreamStart(stream)
    }

    /// What it heard so far, events fseventsd still holds for it included.
    func paths() -> [String] {
        FSEventStreamFlushSync(stream)
        return heard.lock.withLock { heard.paths }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
