import XCTest
@testable import Lilo

/// The extension-to-native-host security boundary: the allowed_origins gate, host names escaping the manifest directory,
/// the length-prefixed frame codec, and `NativeMessagingConnection` against real /bin/sh hosts.
final class NativeMessagingTests: XCTestCase {

    // MARK: - isExtensionAllowed

    func testEmptyAllowedOriginsRefusesEveryone() {
        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: "abc123", origin: "lilo-extension://abc123", allowedOrigins: []))
    }

    func testExactOriginStringMatchIsAllowed() {
        XCTAssertTrue(NativeMessaging.isExtensionAllowed(
            extensionId: "abc123",
            origin: "lilo-extension://abc123",
            allowedOrigins: ["lilo-extension://abc123"]))
    }

    /// allowed_origins entries look like `chrome-extension://<id>/`; we match by host even though
    /// Lilo's own origin scheme differs from Chrome's.
    func testHostMatchesExtensionIdViaChromeExtensionOriginForm() {
        XCTAssertTrue(NativeMessaging.isExtensionAllowed(
            extensionId: "cjpalhdlnbpafiamejdnhcphjbkeiagm",
            origin: "lilo-extension://cjpalhdlnbpafiamejdnhcphjbkeiagm",
            allowedOrigins: ["chrome-extension://cjpalhdlnbpafiamejdnhcphjbkeiagm/"]))
    }

    func testHostMatchWorksWithoutTrailingSlash() {
        XCTAssertTrue(NativeMessaging.isExtensionAllowed(
            extensionId: "cjpalhdlnbpafiamejdnhcphjbkeiagm",
            origin: "irrelevant",
            allowedOrigins: ["chrome-extension://cjpalhdlnbpafiamejdnhcphjbkeiagm"]))
    }

    /// Both the extension id and the allowed_origins entry are lowercased before comparison.
    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(NativeMessaging.isExtensionAllowed(
            extensionId: "ABC123",
            origin: "irrelevant",
            allowedOrigins: ["CHROME-EXTENSION://abc123/"]))
    }

    /// "abc123xyz" must not satisfy a check for "abc123": no accidental prefix matching.
    func testNeighboringExtensionIdIsNotAllowed() {
        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: "abc123",
            origin: "irrelevant",
            allowedOrigins: ["chrome-extension://abc123xyz/"]))
    }

    func testUnrelatedAllowedOriginsRefuse() {
        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: "abc123",
            origin: "lilo-extension://abc123",
            allowedOrigins: ["chrome-extension://zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/", "https://example.com"]))
    }

    /// When the `scheme://<id>` form doesn't parse to a clean URL host (e.g. because the id
    /// contains a character the URL parser rejects, like a space), the implementation falls back
    /// to raw string matching (`contains`) rather than refusing outright.
    func testFallbackToleratesUnparseableSchemeIdFormWithTrailingSlash() {
        let id = "weird id"
        let entry = "scheme://\(id)/"
        XCTAssertNil(URL(string: entry)?.host, "test assumption: URL parsing fails for this id")

        XCTAssertTrue(NativeMessaging.isExtensionAllowed(
            extensionId: id, origin: "irrelevant", allowedOrigins: [entry]))
    }

    /// Same fallback, exercised via the `hasSuffix` branch (no trailing slash after the id).
    func testFallbackToleratesUnparseableSchemeIdFormWithoutTrailingSlash() {
        let id = "weird id"
        let entry = "scheme://\(id)"
        XCTAssertNil(URL(string: entry)?.host, "test assumption: URL parsing fails for this id")

        XCTAssertTrue(NativeMessaging.isExtensionAllowed(
            extensionId: id, origin: "irrelevant", allowedOrigins: [entry]))
    }

    /// The `scheme://<id>` fallback must match only when `<id>` is the entire authority, never `"://<id>/"` embedded
    /// elsewhere (e.g. in a query string).
    func testFallbackDoesNotOverMatchIdEmbeddedInUnrelatedURLQueryString() {
        let id = "abc123"
        let maliciousEntry = "https://attacker.example.com/?redirect=ftp://abc123/end"
        // Sanity check: the entry's *real* host has nothing to do with the extension id.
        XCTAssertEqual(URL(string: maliciousEntry)?.host, "attacker.example.com")

        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: id,
            origin: "totally-unrelated-origin",
            allowedOrigins: [maliciousEntry]))
    }

    /// Same rule for an entry with no trailing slash after the id.
    func testFallbackDoesNotOverMatchIdEmbeddedInUnrelatedURL() {
        let id = "abc123"
        let maliciousEntry = "https://attacker.example.com/?next=custom://abc123"
        XCTAssertEqual(URL(string: maliciousEntry)?.host, "attacker.example.com")

        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: id,
            origin: "totally-unrelated-origin",
            allowedOrigins: [maliciousEntry]))
    }

    /// The canonical attack shape: the id appears as a `chrome-extension://` fragment embedded
    /// inside an unrelated `https://` entry's query string.
    func testFallbackRejectsIdEmbeddedAsChromeExtensionQueryParam() {
        let id = "abc123"
        let maliciousEntry = "https://evil.example/?u=chrome-extension://abc123/"
        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: id, origin: "irrelevant", allowedOrigins: [maliciousEntry]))
    }

    func testChromeExtensionSchemeWithBareIdIsAccepted() {
        XCTAssertTrue(NativeMessaging.isExtensionAllowed(
            extensionId: "abc123", origin: "irrelevant", allowedOrigins: ["chrome-extension://abc123"]))
    }

    func testChromeExtensionSchemeWithTrailingSlashIdIsAccepted() {
        XCTAssertTrue(NativeMessaging.isExtensionAllowed(
            extensionId: "abc123", origin: "irrelevant", allowedOrigins: ["chrome-extension://abc123/"]))
    }

    func testIdWithTrailingExtraCharacterIsRejected() {
        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: "abc123", origin: "irrelevant", allowedOrigins: ["chrome-extension://abc123x"]))
    }

    func testIdWithLeadingExtraCharacterIsRejected() {
        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: "abc123", origin: "irrelevant", allowedOrigins: ["chrome-extension://xabc123"]))
    }

    /// The fallback requires nothing precede `scheme://` but the scheme itself: if the text before
    /// the first `"://"` already contains a `/`, the entry isn't a clean `scheme://<id>` form and
    /// must be rejected, even though the id exactly terminates the string.
    func testSchemePartContainingSlashIsRejected() {
        let id = "abc123"
        let entry = "evil/host://abc123"
        XCTAssertNil(URL(string: entry)?.host, "test assumption: URL parsing doesn't host-match here")

        XCTAssertFalse(NativeMessaging.isExtensionAllowed(
            extensionId: id, origin: "irrelevant", allowedOrigins: [entry]))
    }

    // MARK: - isValidHostName

    func testValidHostNamesAccepted() {
        for name in ["com.example.myhost", "com.example.host_name123", "a", "a.b.c_d123"] {
            XCTAssertTrue(NativeMessaging.isValidHostName(name), "\(name) should be valid")
        }
    }

    func testEmptyHostNameRejected() {
        XCTAssertFalse(NativeMessaging.isValidHostName(""))
    }

    func testPathTraversalRejected() {
        XCTAssertFalse(NativeMessaging.isValidHostName("../evil"))
    }

    func testLeadingDotRejected() {
        XCTAssertFalse(NativeMessaging.isValidHostName(".hidden.host"))
    }

    func testTrailingDotRejected() {
        XCTAssertFalse(NativeMessaging.isValidHostName("evil.host."))
    }

    func testUppercaseRejected() {
        XCTAssertFalse(NativeMessaging.isValidHostName("Com.Example.Host"))
    }

    func testConsecutiveDotsRejected() {
        XCTAssertFalse(NativeMessaging.isValidHostName("com..example"))
    }

    func testNonASCIILettersRejected() {
        XCTAssertFalse(NativeMessaging.isValidHostName("com.exampl\u{e9}"))
    }

    func testOversizeNameRejected() {
        XCTAssertFalse(NativeMessaging.isValidHostName(String(repeating: "a", count: 256)))
    }

    func testNameAtLengthBoundaryAccepted() {
        XCTAssertTrue(NativeMessaging.isValidHostName(String(repeating: "a", count: 255)))
    }

    // MARK: - encodeFrame / extractFrames (frame codec)

    /// Mirrors the `fileprivate` `maxMessageBytes` (64 MiB) in NativeMessaging.swift; keep the two
    /// in sync.
    private let maxMessageBytesMirror = 64 * 1024 * 1024

    private func lengthHeader(_ length: Int) -> Data {
        let count = UInt32(length)
        return Data([
            UInt8(count & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 24) & 0xff)
        ])
    }

    func testEncodeFrameProducesLittleEndianLengthPrefix() throws {
        let message = ["hello": "world"]
        let frame = try XCTUnwrap(NativeMessaging.encodeFrame(message))
        let json = try JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed)

        let header = [UInt8](frame.prefix(4))
        let decodedLength = Int(header[0]) | (Int(header[1]) << 8) | (Int(header[2]) << 16) | (Int(header[3]) << 24)
        XCTAssertEqual(decodedLength, json.count)
        XCTAssertEqual(frame.count, 4 + json.count)
    }

    func testEncodeFrameRejectsMessageLargerThanMaxMessageBytes() {
        // A JSON string payload just over the 64 MiB cap.
        let oversizedString = String(repeating: "a", count: maxMessageBytesMirror + 16)
        XCTAssertNil(NativeMessaging.encodeFrame(oversizedString))
    }

    func testRoundTripSingleMessage() throws {
        let message = ["type": "ping", "value": "42"]
        let frame = try XCTUnwrap(NativeMessaging.encodeFrame(message))

        let result = NativeMessaging.extractFrames(from: frame)
        XCTAssertEqual(result.payloads.count, 1)
        XCTAssertTrue(result.remainder.isEmpty)
        XCTAssertFalse(result.oversizeError)

        let decoded = try JSONSerialization.jsonObject(with: result.payloads[0]) as? [String: String]
        XCTAssertEqual(decoded, message)
    }

    /// Simulates `NativeMessagingConnection.ingest`'s incremental buffer-accumulation pattern:
    /// feed a single frame in three arbitrary chunks (one of which splits the length header
    /// itself), none of which land on a message boundary.
    func testMessageSplitAcrossMultipleChunksReassembles() throws {
        let message = ["type": "ping", "value": String(repeating: "x", count: 5000)]
        let frame = try XCTUnwrap(NativeMessaging.encodeFrame(message))

        let cut1 = 2
        let cut2 = frame.count - 7
        let chunks = [
            frame.subdata(in: 0..<cut1),
            frame.subdata(in: cut1..<cut2),
            frame.subdata(in: cut2..<frame.count)
        ]

        var buffer = Data()
        var payloads: [Data] = []
        for chunk in chunks {
            buffer.append(chunk)
            let result = NativeMessaging.extractFrames(from: buffer)
            payloads.append(contentsOf: result.payloads)
            buffer = result.remainder
            XCTAssertFalse(result.oversizeError)
        }

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(payloads.count, 1)
        let decoded = try JSONSerialization.jsonObject(with: payloads[0]) as? [String: String]
        XCTAssertEqual(decoded, message)
    }

    func testTwoMessagesInOneChunkBothExtracted() throws {
        let messageA = ["id": "a"]
        let messageB = ["id": "b"]
        var combined = try XCTUnwrap(NativeMessaging.encodeFrame(messageA))
        combined.append(try XCTUnwrap(NativeMessaging.encodeFrame(messageB)))

        let result = NativeMessaging.extractFrames(from: combined)
        XCTAssertEqual(result.payloads.count, 2)
        XCTAssertTrue(result.remainder.isEmpty)
        XCTAssertFalse(result.oversizeError)

        let decodedA = try JSONSerialization.jsonObject(with: result.payloads[0]) as? [String: String]
        let decodedB = try JSONSerialization.jsonObject(with: result.payloads[1]) as? [String: String]
        XCTAssertEqual(decodedA, messageA)
        XCTAssertEqual(decodedB, messageB)
    }

    /// Exactly at the cap: allowed. Since no payload bytes follow the header yet, extraction just
    /// waits for more data rather than reporting an oversize error.
    func testHeaderAtMaxMessageBytesBoundaryIsTreatedAsIncompleteNotOversize() {
        let header = lengthHeader(maxMessageBytesMirror)
        let result = NativeMessaging.extractFrames(from: header)
        XCTAssertTrue(result.payloads.isEmpty)
        XCTAssertEqual(result.remainder, header)
        XCTAssertFalse(result.oversizeError)
    }

    func testHeaderOverMaxMessageBytesIsOversizeError() {
        let header = lengthHeader(maxMessageBytesMirror + 1)
        let result = NativeMessaging.extractFrames(from: header)
        XCTAssertTrue(result.payloads.isEmpty)
        XCTAssertEqual(result.remainder, header)
        XCTAssertTrue(result.oversizeError)
    }

    /// A well-formed message followed by a bogus oversize header in the same buffer: the valid
    /// message must still be extracted before the caller is told to disconnect.
    func testOversizeHeaderStopsAfterDeliveringPriorValidMessages() throws {
        let goodFrame = try XCTUnwrap(NativeMessaging.encodeFrame(["ok": "yes"]))
        let badHeader = lengthHeader(maxMessageBytesMirror + 1)
        var buffer = goodFrame
        buffer.append(badHeader)

        let result = NativeMessaging.extractFrames(from: buffer)
        XCTAssertEqual(result.payloads.count, 1)
        XCTAssertTrue(result.oversizeError)
        XCTAssertEqual(result.remainder, badHeader)
    }

    // MARK: - NativeMessagingConnection

    private var hostDirectory: URL!

    override func setUpWithError() throws {
        hostDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMessagingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hostDirectory)
    }

    /// Writes an executable /bin/sh host script and returns its path.
    private func makeHost(_ body: String) throws -> String {
        let url = hostDirectory.appendingPathComponent("host-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// A host that reads the request, writes its reply and exits at once: the reply must always
    /// arrive before the disconnect, never be dropped by the exit.
    func testReplyWrittenJustBeforeExitIsDelivered() throws {
        let host = try makeHost(#"head -c 14 >/dev/null; printf '\013\000\000\000{"ok":true}'"#)
        let request = try XCTUnwrap(NativeMessaging.encodeFrame(["ping": 1]))
        XCTAssertEqual(request.count, 14, "test assumption: the host reads exactly one request frame")
        for iteration in 0..<50 {
            var replies: [Any] = []
            var disconnectError: Error?
            let disconnected = expectation(description: "disconnect \(iteration)")
            let connection = try XCTUnwrap(NativeMessagingConnection(
                executablePath: host, extensionOrigin: "chrome-extension://abc/",
                onMessage: { replies.append($0) },
                onDisconnect: { disconnectError = $0; disconnected.fulfill() }))
            connection.send(frame: request)
            wait(for: [disconnected], timeout: 10)
            XCTAssertEqual(replies.count, 1, "iteration \(iteration)")
            XCTAssertEqual((replies.first as? [String: Bool])?["ok"], true, "iteration \(iteration)")
            XCTAssertNil(disconnectError, "iteration \(iteration)")
        }
    }

    /// Writing to a host that closed its stdin must fail the connection with an error rather than
    /// raise SIGPIPE, which would kill the whole process.
    func testWriteToHostThatClosedStdinDisconnectsWithError() throws {
        let host = try makeHost(#"exec 0<&-; printf '\016\000\000\000{"ready":true}'; exec sleep 30"#)
        let disconnected = expectation(description: "disconnect")
        var disconnectError: Error?
        var connection: NativeMessagingConnection?
        connection = try XCTUnwrap(NativeMessagingConnection(
            executablePath: host, extensionOrigin: "chrome-extension://abc/",
            onMessage: { _ in connection?.send(["ping": 1]) },
            onDisconnect: { disconnectError = $0; disconnected.fulfill() }))
        wait(for: [disconnected], timeout: 10)
        XCTAssertNotNil(disconnectError)
        connection = nil
    }

    func testHostExitingImmediatelyDisconnects() throws {
        let host = try makeHost("exit 0")
        let disconnected = expectation(description: "disconnect")
        let connection = try XCTUnwrap(NativeMessagingConnection(
            executablePath: host, extensionOrigin: "chrome-extension://abc/",
            onMessage: { _ in XCTFail("unexpected message") },
            onDisconnect: { _ in disconnected.fulfill() }))
        connection.send(frame: Data(repeating: 0, count: 256 * 1024))
        wait(for: [disconnected], timeout: 10)
    }

    /// A host that never reads fills the stdin pipe and blocks the write; disconnecting must still
    /// complete.
    func testDisconnectCompletesWhileWriteIsBlocked() throws {
        let host = try makeHost("exec sleep 30")
        let disconnected = expectation(description: "disconnect")
        let connection = try XCTUnwrap(NativeMessagingConnection(
            executablePath: host, extensionOrigin: "chrome-extension://abc/",
            onMessage: { _ in },
            onDisconnect: { _ in disconnected.fulfill() }))
        connection.send(frame: Data(repeating: 0, count: 1024 * 1024))
        connection.disconnect()
        wait(for: [disconnected], timeout: 10)
    }

    func testNonJSONMessageDisconnectsWithError() throws {
        let host = try makeHost(#"printf '\004\000\000\000nope'; exec sleep 30"#)
        let disconnected = expectation(description: "disconnect")
        var disconnectError: Error?
        let connection = try XCTUnwrap(NativeMessagingConnection(
            executablePath: host, extensionOrigin: "chrome-extension://abc/",
            onMessage: { _ in XCTFail("unexpected message") },
            onDisconnect: { disconnectError = $0; disconnected.fulfill() }))
        wait(for: [disconnected], timeout: 10)
        XCTAssertNotNil(disconnectError)
        withExtendedLifetime(connection) {}
    }
}
