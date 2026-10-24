// Chrome-compatible native messaging: 4-byte little-endian length-prefixed UTF-8 JSON over the host's stdin/stdout.
// Launching host executables requires Lilo to stay un-sandboxed.

import Foundation
import os

enum NativeMessaging {
    fileprivate static let logger = Logger(liloCategory: "native-messaging")

    /// Largest message we will frame or accept, guarding against a rogue length header.
    fileprivate static let maxMessageBytes = 64 * 1024 * 1024

    /// Chrome's own messages: extensions match them (Claude tells an absent host from a broken one by its text).
    fileprivate enum NativeMessagingError: LocalizedError {
        case invalidName
        case noHost
        case originNotAllowed
        case launchFailed
        case disconnected
        case communication

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Invalid native messaging host name specified."
            case .noHost: return "Specified native messaging host not found."
            case .originNotAllowed: return "Access to the specified native messaging host is forbidden."
            case .launchFailed: return "Failed to start native messaging host."
            case .disconnected: return "Native host has exited."
            case .communication: return "Error when communicating with the native messaging host."
            }
        }
    }

    /// Chrome's `allowed_origins` check: an empty list denies everyone; entries match the exact origin or the extension id as host.
    /// Without it any loaded extension could reach any native host installed system-wide.
    static func isExtensionAllowed(extensionId: String, origin: String, allowedOrigins: [String]) -> Bool {
        guard !allowedOrigins.isEmpty else { return false }
        let id = extensionId.lowercased()
        let originLower = origin.lowercased()
        return allowedOrigins.contains { entry in
            let e = entry.lowercased()
            if e == originLower { return true }
            if let host = URL(string: e)?.host, host == id { return true }
            // Tolerates `scheme://<id>[/]` forms the URL parser may not host-split; the id must be the entry's entire authority
            // (no "/" before the first "://", nothing but `id` or `id/` after it), never merely contained in it.
            guard let schemeRange = e.range(of: "://"), !e[e.startIndex..<schemeRange.lowerBound].contains("/") else { return false }
            let remainder = e[schemeRange.upperBound...]
            return remainder == id || remainder == "\(id)/"
        }
    }

    /// Directories searched for `<name>.json`, in priority order: Lilo's own first, then the
    /// browsers whose hosts (password managers, etc.) are commonly installed system-wide. An isolated
    /// data folder (LILO_APP_SUPPORT_DIR) searches only its own, so tests never start the Mac's hosts.
    private static let manifestDirectories: [String] = {
        if let isolated = ProcessInfo.processInfo.environment["LILO_APP_SUPPORT_DIR"], !isolated.isEmpty {
            return ["\(isolated)/NativeMessagingHosts"]
        }
        let appSupport = "\(NSHomeDirectory())/Library/Application Support"
        return [
            "\(appSupport)/Lilo/NativeMessagingHosts",
            "\(appSupport)/Google/Chrome/NativeMessagingHosts",
            "\(appSupport)/Google/Chrome Beta/NativeMessagingHosts",
            "\(appSupport)/Google/Chrome Dev/NativeMessagingHosts",
            "\(appSupport)/Google/Chrome Canary/NativeMessagingHosts",
            "/Library/Google/Chrome/NativeMessagingHosts",
            "\(appSupport)/Chromium/NativeMessagingHosts",
            "/Library/Application Support/Chromium/NativeMessagingHosts",
            "\(appSupport)/Microsoft Edge/NativeMessagingHosts",
            "/Library/Microsoft/Edge/NativeMessagingHosts",
            "\(appSupport)/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "\(appSupport)/Arc/User Data/NativeMessagingHosts",
            "\(appSupport)/Vivaldi/NativeMessagingHosts"
        ]
    }()

    /// Chrome's host name rule: lowercase ASCII letters, digits, underscores and dots, with no
    /// leading, trailing or consecutive dots. Also keeps the name inside the manifest directory.
    static func isValidHostName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."), !name.hasSuffix("."),
              !name.contains("..") else { return false }
        return name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 46 }
    }

    /// Returns the executable of the first manifest for `name` that allows the calling extension.
    /// Manifests are read on every call so installs and removals apply without a relaunch.
    static func locateHost(named name: String, extensionId: String, extensionOrigin: String) throws -> String {
        guard isValidHostName(name) else {
            logger.error("Rejected invalid native messaging host name: \(name, privacy: .public)")
            throw NativeMessagingError.invalidName
        }
        var foundDisallowed = false
        for dir in manifestDirectories {
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(name).json"),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (object["type"] as? String) == "stdio",
                  let path = object["path"] as? String, path.hasPrefix("/") else { continue }
            guard isExtensionAllowed(extensionId: extensionId, origin: extensionOrigin,
                                     allowedOrigins: object["allowed_origins"] as? [String] ?? []) else {
                foundDisallowed = true
                continue
            }
            guard FileManager.default.isExecutableFile(atPath: path) else {
                logger.error("Native messaging host \(name, privacy: .public) is not executable: \(path, privacy: .public)")
                continue
            }
            return path
        }
        if foundDisallowed {
            logger.error("Extension \(extensionId, privacy: .public) not in allowed_origins for host \(name, privacy: .public)")
            throw NativeMessagingError.originNotAllowed
        }
        logger.error("No native messaging host manifest found for \(name, privacy: .public)")
        throw NativeMessagingError.noHost
    }

    static func encodeFrame(_ message: Any) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed),
              json.count <= maxMessageBytes else { return nil }
        let count = UInt32(json.count)
        var frame = Data([
            UInt8(count & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 24) & 0xff)
        ])
        frame.append(json)
        return frame
    }

    /// Peels complete length-prefixed frames off `buffer`, stopping at the first header over `maxMessageBytes`, after which the
    /// caller must disconnect.
    static func extractFrames(from buffer: Data) -> (payloads: [Data], remainder: Data, oversizeError: Bool) {
        var buffer = buffer
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            let length = Int(header[0]) | (Int(header[1]) << 8) | (Int(header[2]) << 16) | (Int(header[3]) << 24)
            guard length >= 0, length <= maxMessageBytes else {
                return (payloads, buffer, true)
            }
            guard buffer.count >= 4 + length else { break }
            payloads.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return (payloads, buffer, false)
    }

    /// A host that neither replies nor exits within this is disconnected, so the reply fails instead of
    /// leaving a process and its extension callback pending forever.
    static let oneShotTimeout: TimeInterval = 30

    /// Resolves, authorizes and launches `hostName`.
    static func connect(
        hostName: String,
        extensionId: String,
        extensionOrigin: String,
        onMessage: @escaping (Any) -> Void,
        onDisconnect: @escaping (Error?) -> Void
    ) throws -> NativeMessagingConnection {
        let executablePath = try locateHost(named: hostName, extensionId: extensionId, extensionOrigin: extensionOrigin)
        guard let connection = NativeMessagingConnection(executablePath: executablePath, extensionOrigin: extensionOrigin,
                                                         onMessage: onMessage, onDisconnect: onDisconnect) else {
            throw NativeMessagingError.launchFailed
        }
        return connection
    }

    /// One-shot request/response (`chrome.runtime.sendNativeMessage`): launch the host, send one
    /// message, return the first reply, then terminate. Callbacks are delivered on the main queue.
    static func sendOneShot(
        hostName: String,
        message: Any,
        extensionOrigin: String,
        extensionId: String,
        reply: @escaping @Sendable (Result<Any, Error>) -> Void
    ) {
        guard let frame = encodeFrame(message) else {
            DispatchQueue.main.async { reply(.failure(NativeMessagingError.communication)) }
            return
        }
        var keepAlive: NativeMessagingConnection?
        var replied = false
        let connection: NativeMessagingConnection
        do {
            connection = try connect(
                hostName: hostName,
                extensionId: extensionId,
                extensionOrigin: extensionOrigin,
                onMessage: { message in
                    guard !replied else { return }
                    replied = true
                    reply(.success(message))
                    // Still held until onDisconnect: the queued finish only weakly holds the connection
                    // and is what terminates the host.
                    keepAlive?.disconnect()
                },
                onDisconnect: { error in
                    if !replied {
                        replied = true
                        reply(.failure(error ?? NativeMessagingError.disconnected))
                    }
                    keepAlive = nil
                }
            )
        } catch {
            DispatchQueue.main.async { reply(.failure(error)) }
            return
        }
        keepAlive = connection
        connection.send(frame: frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + oneShotTimeout) {
            keepAlive?.disconnect()
        }
    }
}

/// One running native host process. Callbacks run on the main queue; the connection ends on stdout EOF, never process exit, so a
/// last reply is delivered. `@unchecked Sendable`: `buffer`/`didDisconnect` stay on `queue`, `stdinClosed` on `writeQueue`.
final class NativeMessagingConnection: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let queue = DispatchQueue(label: "fr.arouillard.lilo.native-messaging.connection")
    /// Writes block while the host's stdin pipe is full, so they stay off `queue`.
    private let writeQueue = DispatchQueue(label: "fr.arouillard.lilo.native-messaging.write")
    private var buffer = Data()
    private var didDisconnect = false
    private var stdinClosed = false
    private let onMessage: (Any) -> Void
    private let onDisconnect: (Error?) -> Void

    init?(
        executablePath: String,
        extensionOrigin: String,
        onMessage: @escaping (Any) -> Void,
        onDisconnect: @escaping (Error?) -> Void
    ) {
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect

        let executableURL = URL(fileURLWithPath: executablePath)
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.arguments = [extensionOrigin]   // Chrome convention: argv[1] is the calling origin.
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { self.ingest(data) }
        }
        do {
            try process.run()
        } catch {
            NativeMessaging.logger.error("Failed to launch native messaging host: \(error.localizedDescription, privacy: .public)")
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
    }

    func send(_ message: Any) {
        guard let frame = NativeMessaging.encodeFrame(message) else { return }
        send(frame: frame)
    }

    func send(frame: Data) {
        writeQueue.async { [weak self] in
            guard let self, !self.stdinClosed else { return }
            do {
                try self.stdinPipe.fileHandleForWriting.write(contentsOf: frame)
            } catch {
                self.queue.async { self.finish(error: error) }
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in self?.finish(error: nil) }
    }

    private func ingest(_ data: Data) {
        guard !didDisconnect else { return }
        if data.isEmpty { finish(error: nil); return }   // EOF
        buffer.append(data)
        let (payloads, remainder, oversizeError) = NativeMessaging.extractFrames(from: buffer)
        buffer = remainder
        for payload in payloads {
            guard let object = try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed) else {
                finish(error: NativeMessaging.NativeMessagingError.communication)
                return
            }
            DispatchQueue.main.async { [weak self] in self?.onMessage(object) }
        }
        if oversizeError {
            finish(error: NativeMessaging.NativeMessagingError.disconnected)
        }
    }

    private func finish(error: Error?) {
        guard !didDisconnect else { return }
        didDisconnect = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        // Queued behind any blocked write, which the SIGTERM/SIGKILL below unblocks with EPIPE.
        writeQueue.async { [self] in
            stdinClosed = true
            try? stdinPipe.fileHandleForWriting.close()
        }
        if process.isRunning {
            process.terminate()
            let process = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onDisconnect(error) }
    }
}
