import XCTest
@testable import Lilo

final class BrowserImportScannerTests: XCTestCase {
    private var home: URL!
    private let chrome = "Library/Application Support/Google/Chrome"
    private var denied: [String] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        for path in denied { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        try? FileManager.default.removeItem(at: home)
    }

    private func touch(_ path: String, _ contents: String = "") throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// File permissions refuse the read with EACCES, as macOS privacy refuses it with EPERM.
    private func deny(_ path: String) throws {
        let path = home.appendingPathComponent(path).path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        denied.append(path)
    }

    private func writeChromeWithProfile1Only() throws {
        try touch("\(chrome)/Local State", #"{"profile": {"info_cache": {"Profile 1": {"name": "Personal"}}, "last_used": "Profile 1"}}"#)
        try touch("\(chrome)/Profile 1/Bookmarks", #"{"roots": {"bookmark_bar": {"children": [], "type": "folder"}}, "version": 1}"#)
        try touch("\(chrome)/Profile 1/History")
    }

    func testFindsChromeProfilesFirefoxProfilesAndNothingElse() throws {
        try touch("\(chrome)/Local State", #"{"profile": {"info_cache": {"Default": {"name": "Perso"}, "Profile 1": {"name": "Travail"}}}}"#)
        try touch("\(chrome)/Default/Bookmarks", "{}")
        try touch("\(chrome)/Profile 1/History")
        let firefox = "Library/Application Support/Firefox"
        try touch("\(firefox)/profiles.ini", "[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abc.default-release\n")
        try touch("\(firefox)/Profiles/abc.default-release/places.sqlite")

        let sources = BrowserImportScanner.scan(home: home, isInstalled: { _ in true })
        XCTAssertEqual(sources.map(\.id), ["chrome", "firefox"])
        XCTAssertEqual(sources[0].profiles.map(\.name), ["Perso", "Travail"])
        XCTAssertEqual(sources[0].profiles[0].kinds, [.bookmarks])
        XCTAssertEqual(sources[1].profiles.first?.kinds, [.bookmarks, .history])
    }

    func testChromeWithOnlyAProfile1IsFound() throws {
        try writeChromeWithProfile1Only()

        let chrome = try XCTUnwrap(BrowserImportScanner.scan(home: home, isInstalled: { _ in true }).first { $0.id == "chrome" })
        XCTAssertFalse(chrome.needsFullDiskAccess)
        XCTAssertEqual(chrome.profiles.map(\.id), ["Profile 1"])
        XCTAssertEqual(chrome.profiles.map(\.name), ["Personal"])
        XCTAssertEqual(chrome.profiles[0].kinds, [.bookmarks, .history])
    }

    func testChromeProfileFoldersAreFoundWithoutALocalState() throws {
        try touch("\(chrome)/Profile 1/Bookmarks", "{}")
        try touch("\(chrome)/Profile 2/History")
        try touch("\(chrome)/System Profile/History")

        let chrome = try XCTUnwrap(BrowserImportScanner.scan(home: home, isInstalled: { _ in true }).first { $0.id == "chrome" })
        XCTAssertEqual(chrome.profiles.map(\.id), ["Profile 1", "Profile 2"])
    }

    func testAnUnreadableChromeIsListedAsNeedingAccess() throws {
        try writeChromeWithProfile1Only()
        try deny(chrome)

        let sources = BrowserImportScanner.scan(home: home, isInstalled: { _ in true })
        let chrome = try XCTUnwrap(sources.first { $0.id == "chrome" })
        XCTAssertTrue(chrome.needsFullDiskAccess)
        XCTAssertEqual(chrome.profiles, [])
    }

    func testAnUnreadableLocalStateIsADenialNotAMissingProfile() throws {
        try writeChromeWithProfile1Only()
        try deny("\(chrome)/Local State")

        XCTAssertEqual(BrowserImportScanner.scan(home: home, isInstalled: { _ in true }).first { $0.id == "chrome" }?.needsFullDiskAccess, true)
    }

    func testAMissingBrowserIsNotADenial() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        XCTAssertEqual(BrowserImportScanner.scan(home: home, isInstalled: { _ in true }).map(\.id), [])
    }

    func testAnUnreadableFirefoxIsListedAsNeedingAccess() throws {
        try touch("Library/Application Support/Firefox/profiles.ini", "[Profile0]\nPath=Profiles/a\n")
        try deny("Library/Application Support/Firefox")

        XCTAssertEqual(BrowserImportScanner.scan(home: home, isInstalled: { _ in true }).first { $0.id == "firefox" }?.needsFullDiskAccess, true)
    }

    /// Password managers make a folder per browser for their native helpers, which macOS may keep from Lilo.
    func testAnUnreadableFolderOfABrowserNotInstalledIsLeftOut() throws {
        try touch("Library/Application Support/Microsoft Edge/NativeMessagingHosts/helper.json", "{}")
        try deny("Library/Application Support/Microsoft Edge")

        XCTAssertNil(BrowserImportScanner.scan(home: home, isInstalled: { _ in false }).first { $0.id == "edge" })
    }

    func testTheReadableProfilesOfAnUninstalledBrowserAreLeftOut() throws {
        try writeChromeWithProfile1Only()

        XCTAssertNil(BrowserImportScanner.scan(home: home, isInstalled: { _ in false }).first { $0.id == "chrome" })
    }

    func testUnreadableSafariNeedsFullDiskAccess() throws {
        try touch("Library/Safari/Bookmarks.plist")
        try deny("Library/Safari")
        let safari = BrowserImportScanner.scan(home: home, isInstalled: { _ in true }).first { $0.id == "safari" }
        XCTAssertEqual(safari?.needsFullDiskAccess, true)
    }

    func testReadableSafariWithoutBookmarksNeedsNoAccess() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
        let safari = BrowserImportScanner.scan(home: home, isInstalled: { _ in true }).first { $0.id == "safari" }
        XCTAssertEqual(safari?.needsFullDiskAccess, false)
    }
}
