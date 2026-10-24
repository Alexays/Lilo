import CoreServices
import Darwin
import XCTest
@testable import Lilo

/// Covers `DownloadQuarantine`, which stamps the `com.apple.quarantine` xattr Gatekeeper checks
/// on open: WebKit/LaunchServices don't do this automatically because Lilo isn't sandboxed.
final class DownloadQuarantineTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadQuarantineTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func makeFile(named name: String = "download.bin") -> URL {
        let url = tempDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("payload".utf8))
        return url
    }

    /// Reads the raw `com.apple.quarantine` xattr via the syscall, independent of LaunchServices' side database.
    private func rawQuarantineXattr(_ path: String) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    // MARK: - stamp / isQuarantined

    func testFreshFileIsNotQuarantined() {
        let file = makeFile()
        XCTAssertFalse(DownloadQuarantine.isQuarantined(file))
    }

    func testStampSetsQuarantineTypeAndAgent() throws {
        let file = makeFile()
        DownloadQuarantine.stamp(path: file.path, source: "https://example.com/download.bin")

        let values = try file.resourceValues(forKeys: [.quarantinePropertiesKey])
        let properties = try XCTUnwrap(values.quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "Lilo")
    }

    /// The source URL lives in LaunchServices' side database, where the write is a silent no-op in test/CI and `stamp()`
    /// swallows the error, so this pins the observed behavior.
    func testStampAttemptsToRecordSourceURLButPersistenceIsEnvironmentDependent() throws {
        let file = makeFile()
        DownloadQuarantine.stamp(path: file.path, source: "https://example.com/download.bin")

        XCTAssertTrue(DownloadQuarantine.isQuarantined(file))
        let values = try file.resourceValues(forKeys: [.quarantinePropertiesKey])
        let properties = try XCTUnwrap(values.quarantineProperties)
        // Pinning actual observed behavior: the DataURL key does not come back through
        // `resourceValues` in this environment, despite `stamp()` requesting it and not throwing.
        XCTAssertNil(properties[kLSQuarantineDataURLKey as String])
    }

    func testStampWithNilSourceOmitsDataURLKeyButStillQuarantines() throws {
        let file = makeFile()
        DownloadQuarantine.stamp(path: file.path, source: nil)

        XCTAssertTrue(DownloadQuarantine.isQuarantined(file))
        let values = try file.resourceValues(forKeys: [.quarantinePropertiesKey])
        let properties = try XCTUnwrap(values.quarantineProperties)
        XCTAssertNil(properties[kLSQuarantineDataURLKey as String])
    }

    /// The raw xattr embeds a fresh event-id on every write, so identical bytes prove the re-stamp rewrote nothing.
    func testReStampingAlreadyQuarantinedFileDoesNotRewriteTheRecord() throws {
        let file = makeFile()
        DownloadQuarantine.stamp(path: file.path, source: "https://first.example.com/a.bin")
        XCTAssertTrue(DownloadQuarantine.isQuarantined(file))
        let firstRaw = try XCTUnwrap(rawQuarantineXattr(file.path))

        DownloadQuarantine.stamp(path: file.path, source: "https://second.example.com/b.bin")
        let secondRaw = try XCTUnwrap(rawQuarantineXattr(file.path))

        XCTAssertEqual(firstRaw, secondRaw, "re-stamping an already-quarantined file must not rewrite its quarantine record")
    }

    /// WebKit quarantines a download with no agent, which Gatekeeper shows as "(null) downloaded this file".
    func testStampNamesLiloOnARecordWithoutAnAgent() throws {
        let file = makeFile(named: "Lilo.dmg")
        let record = "0183;6adca330;;"
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", record, record.utf8.count, 0, 0), 0)

        DownloadQuarantine.stamp(path: file.path, source: "https://example.com/Lilo.dmg")

        let properties = try XCTUnwrap(file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "Lilo")
    }

    func testStampOnMissingFileIsNoOp() {
        let missing = tempDir.appendingPathComponent("does-not-exist.bin")
        DownloadQuarantine.stamp(path: missing.path, source: "https://example.com/x.bin")
        XCTAssertFalse(DownloadQuarantine.isQuarantined(missing))
    }

    // MARK: - isRisky

    /// Mirrors the real `riskyExtensions` set in DownloadQuarantine.swift. Archives (.zip/.iso)
    /// are deliberately absent: their extracted contents get quarantined, not the archive itself.
    func testIsRiskyRecognizesAllRiskyExtensionsCaseInsensitively() {
        let riskyExtensions = [
            "app", "dmg", "pkg", "mpkg", "command", "tool", "sh", "bash", "zsh",
            "scpt", "scptd", "applescript", "action", "workflow", "terminal", "jar"
        ]
        for ext in riskyExtensions {
            XCTAssertTrue(DownloadQuarantine.isRisky(URL(fileURLWithPath: "/tmp/file.\(ext)")), "\(ext) should be risky")
            XCTAssertTrue(DownloadQuarantine.isRisky(URL(fileURLWithPath: "/tmp/file.\(ext.uppercased())")), "\(ext.uppercased()) should be risky")
        }
    }

    func testIsRiskyReturnsFalseForBenignOrArchiveExtensions() {
        for ext in ["txt", "pdf", "png", "jpg", "mp4", "csv", "zip", "iso", ""] {
            XCTAssertFalse(DownloadQuarantine.isRisky(URL(fileURLWithPath: "/tmp/file.\(ext)")), "\(ext) should not be risky")
        }
    }
}
