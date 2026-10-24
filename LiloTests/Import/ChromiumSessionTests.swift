import XCTest
@testable import Lilo

/// Writes SNSS command logs with the record and payload layout of Chromium's session_service_commands.cc.
struct SNSSWriter {
    private(set) var data = Data("SNSS".utf8) + Self.int(3)

    private static func int(_ value: Int32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func aligned(_ data: Data) -> Data { data + Data(count: (4 - data.count % 4) % 4) }
    private static func string(_ value: String) -> Data { aligned(int(Int32(value.utf8.count)) + Data(value.utf8)) }
    private static func string16(_ value: String) -> Data {
        aligned(int(Int32(value.utf16.count)) + value.utf16.reduce(into: Data()) { $0 += withUnsafeBytes(of: $1.littleEndian) { Data($0) } })
    }
    private static func pickle(_ body: Data) -> Data { int(Int32(body.count)) + body }

    private mutating func command(_ id: UInt8, _ payload: Data) {
        data += withUnsafeBytes(of: UInt16(payload.count + 1).littleEndian) { Data($0) }
        data.append(id)
        data += payload
    }

    mutating func tabWindow(_ window: Int32, tab: Int32, index: Int32) {
        command(0, Self.int(window) + Self.int(tab))
        command(2, Self.int(tab) + Self.int(index))
    }
    mutating func windowType(_ window: Int32, _ type: Int32) { command(9, Self.int(window) + Self.int(type)) }
    /// Writes each entry, then selects `selected`.
    mutating func navigations(tab: Int32, _ entries: [(url: String, title: String)], selected: Int32) {
        for (index, entry) in entries.enumerated() {
            // Trailing fields (page state, transition) are written as Chromium does, and never read.
            command(6, Self.pickle(Self.int(tab) + Self.int(Int32(index)) + Self.string(entry.url) + Self.string16(entry.title)
                + Self.string("state") + Self.int(0)))
        }
        command(7, Self.int(tab) + Self.int(selected))
    }
    mutating func prunedFromBack(tab: Int32, count: Int32) { command(5, Self.int(tab) + Self.int(count)) }
    mutating func pinned(_ tab: Int32) { command(12, Self.int(tab) + Data([1, 0, 0, 0])) }
    mutating func tabClosed(_ tab: Int32) { command(16, Self.int(tab) + Data(count: 4) + Self.uint64(1)) }
    mutating func windowClosed(_ window: Int32) { command(17, Self.int(window) + Data(count: 4) + Self.uint64(1)) }
    mutating func group(tab: Int32, _ token: UInt64) {
        command(25, Self.int(tab) + Data(count: 4) + Self.uint64(token) + Self.uint64(~token) + Data([1]) + Data(count: 7))
    }
    mutating func groupMetadata(_ token: UInt64, title: String, color: Int32) {
        command(27, Self.pickle(Self.uint64(token) + Self.uint64(~token) + Self.string16(title) + Self.int(color) + Data([0, 0, 0, 0])))
    }
}

final class ChromiumSessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chromium-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func read(_ session: SNSSWriter, as name: String = "Sessions/Session_13300000000000000") throws -> ImportReadResult {
        try session.data.write(to: dir.appendingPathComponent(name))
        let profile = ImportProfile(id: "Default", name: "Perso", url: dir, kinds: [.tabs], extensions: [])
        return ChromiumReader.read(profile: profile, kinds: [.tabs], arc: nil, password: { "" })
    }

    func testReplaysWindowsInOrderAndImportsOnlyEachTabsCurrentEntry() throws {
        var session = SNSSWriter()
        session.windowType(7, 0)
        session.tabWindow(7, tab: 1, index: 1)
        session.tabWindow(7, tab: 2, index: 0)
        session.navigations(tab: 1, [("https://a.example/", "A")], selected: 0)
        session.navigations(tab: 2, [("https://old.example/", "Old"), ("https://b.example/", "B"), ("https://next.example/", "Next")], selected: 1)
        session.tabWindow(7, tab: 3, index: 2)
        session.navigations(tab: 3, [("chrome://newtab/", "New Tab")], selected: 0)
        session.tabWindow(7, tab: 4, index: 3)
        session.navigations(tab: 4, [("file:///Users/me/notes.html", "Notes")], selected: 0)
        session.tabWindow(7, tab: 5, index: 4)
        session.navigations(tab: 5, [("https://closed.example/", "Closed")], selected: 0)
        session.tabClosed(5)
        session.tabWindow(8, tab: 6, index: 0)
        session.navigations(tab: 6, [("https://c.example/", "C"), ("https://forward.example/", "Gone"), ("https://forward2.example/", "Gone")], selected: 0)
        session.prunedFromBack(tab: 6, count: 1)
        session.tabWindow(9, tab: 7, index: 0)
        session.navigations(tab: 7, [("https://closed-window.example/", "W")], selected: 0)
        session.windowClosed(9)
        session.windowType(10, 1)
        session.tabWindow(10, tab: 8, index: 0)
        session.navigations(tab: 8, [("https://popup.example/", "Popup")], selected: 0)

        let result = try read(session)
        XCTAssertNil(result.errors[.tabs])
        XCTAssertEqual(result.bundle.openTabs, [
            ImportedBookmark(title: "B", url: "https://b.example/"),
            ImportedBookmark(title: "A", url: "https://a.example/"),
            ImportedBookmark(title: "Notes", url: "file:///Users/me/notes.html"),
            ImportedBookmark(title: "C", url: "https://c.example/")
        ])
        XCTAssertTrue(result.bundle.pinnedTabs.isEmpty)
    }

    func testPinnedTabsAndTitledGroupsWithUTF16Titles() throws {
        let unicode = "Caf\u{e9} \u{65e5}\u{672c} \u{1F600}"
        var session = SNSSWriter()
        session.tabWindow(1, tab: 1, index: 0)
        session.navigations(tab: 1, [("https://mail.example/", "Mail")], selected: 0)
        session.pinned(1)
        session.tabWindow(1, tab: 2, index: 1)
        session.navigations(tab: 2, [("https://docs.example/", unicode)], selected: 0)
        session.tabWindow(1, tab: 3, index: 2)
        session.navigations(tab: 3, [("https://sheets.example/", "Sheets")], selected: 0)
        session.tabWindow(1, tab: 4, index: 3)
        session.navigations(tab: 4, [("https://news.example/", "News")], selected: 0)
        session.group(tab: 2, 42)
        session.group(tab: 3, 42)
        session.groupMetadata(42, title: "Travail \u{e0} faire", color: 1)

        let result = try read(session)
        XCTAssertEqual(result.bundle.pinnedTabs, [ImportedBookmark(title: "Mail", url: "https://mail.example/")])
        XCTAssertEqual(result.bundle.openTabs, [
            ImportedBookmark(title: "Travail \u{e0} faire", url: nil, children: [
                ImportedBookmark(title: unicode, url: "https://docs.example/"),
                ImportedBookmark(title: "Sheets", url: "https://sheets.example/")
            ], color: "#5b7cff"),
            ImportedBookmark(title: "News", url: "https://news.example/")
        ])
    }

    func testATruncatedFileImportsWhatWasReadAndAForeignOneIsAnError() throws {
        var session = SNSSWriter()
        session.tabWindow(1, tab: 1, index: 0)
        session.navigations(tab: 1, [("https://a.example/", "A")], selected: 0)
        let complete = session.data.count
        session.tabWindow(1, tab: 2, index: 1)
        session.navigations(tab: 2, [("https://b.example/", "B")], selected: 0)
        for cut in complete..<session.data.count {
            let tabs = try ChromiumSession.parse(session.data.prefix(cut)).open
            XCTAssertEqual(tabs.first?.url, "https://a.example/", "cut at \(cut)")
        }
        XCTAssertThrowsError(try ChromiumSession.parse(Data("SNS".utf8)))
        XCTAssertThrowsError(try ChromiumSession.parse(Data("{\"roots\": {}}".utf8)))
    }

    func testReadsTheNewestSessionFileOrTheLegacyCurrentSession() throws {
        func session(_ url: String) -> SNSSWriter {
            var session = SNSSWriter()
            session.tabWindow(1, tab: 1, index: 0)
            session.navigations(tab: 1, [(url, "")], selected: 0)
            return session
        }
        try session("https://legacy.example/").data.write(to: dir.appendingPathComponent("Current Session"))
        XCTAssertEqual(try read(session("https://old.example/"), as: "Sessions/Session_9").bundle.openTabs.map(\.url), ["https://old.example/"])
        try session("https://closed-tabs.example/").data.write(to: dir.appendingPathComponent("Sessions/Tabs_99"))
        XCTAssertEqual(try read(session("https://new.example/"), as: "Sessions/Session_10").bundle.openTabs.map(\.url), ["https://new.example/"])

        try FileManager.default.removeItem(at: dir.appendingPathComponent("Sessions"))
        let profile = ImportProfile(id: "Default", name: "Perso", url: dir, kinds: [.tabs], extensions: [])
        XCTAssertEqual(ChromiumReader.read(profile: profile, kinds: [.tabs], arc: nil, password: { "" }).bundle.openTabs.map(\.url),
                       ["https://legacy.example/"])
    }
}
