import XCTest
@testable import Lilo

final class BrowserImportScannerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func touch(_ path: String, _ contents: String = "") throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func testFindsChromeProfilesFirefoxProfilesAndNothingElse() throws {
        let chrome = "Library/Application Support/Google/Chrome"
        try touch("\(chrome)/Local State", #"{"profile": {"info_cache": {"Default": {"name": "Perso"}, "Profile 1": {"name": "Travail"}}}}"#)
        try touch("\(chrome)/Default/Bookmarks", "{}")
        try touch("\(chrome)/Profile 1/History")
        let firefox = "Library/Application Support/Firefox"
        try touch("\(firefox)/profiles.ini", "[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abc.default-release\n")
        try touch("\(firefox)/Profiles/abc.default-release/places.sqlite")

        let sources = BrowserImportScanner.scan(home: home)
        XCTAssertEqual(sources.map(\.id), ["chrome", "firefox"])
        XCTAssertEqual(sources[0].profiles.map(\.name), ["Perso", "Travail"])
        XCTAssertEqual(sources[0].profiles[0].kinds, [.bookmarks])
        XCTAssertEqual(sources[1].profiles.first?.kinds, [.bookmarks, .history])
    }

    func testSafariWithoutReadableBookmarksNeedsFullDiskAccess() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
        let safari = BrowserImportScanner.scan(home: home).first { $0.id == "safari" }
        XCTAssertEqual(safari?.needsFullDiskAccess, true)
    }
}
