import Darwin
import Foundation
import os

/// The agent control socket: a Unix domain socket only processes of the same user may connect to.
/// Messages are UTF-8 JSON, one per line.
@MainActor
final class AgentSocketServer {
    enum SocketError: LocalizedError {
        case pathTooLong, inUse, system(String, Int32)
        var errorDescription: String? {
            switch self {
            case .pathTooLong: "Agent socket path is too long"
            case .inUse: "Another Lilo already serves agents on this socket"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    private static let logger = Logger(liloCategory: "agent-socket")
    private let path: URL
    private let onConnection: (AgentConnection) -> Void
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    /// The bound socket file, so stop never unlinks a socket another Lilo bound at the same path since.
    private var boundFile: (device: dev_t, inode: ino_t)?

    init(path: URL, onConnection: @escaping (AgentConnection) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    func start() throws {
        guard listener < 0 else { return }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        // A socket that still accepts belongs to a running Lilo on the same data folder: taking it over would send
        // that Lilo's agents here. Only a socket left by a crash, which refuses connections, is replaced.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw SocketError.system("socket", errno) }
        let live = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        Darwin.close(probe)
        guard !live else { throw SocketError.inUse }
        unlink(path.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let code = errno; Darwin.close(fd); throw SocketError.system("bind", code) }
        var file = stat()
        if stat(path.path, &file) == 0 { boundFile = (file.st_dev, file.st_ino) }
        // The peer uid check on accept is the real gate; the mode keeps other users from even connecting.
        guard chmod(path.path, 0o600) == 0, listen(fd, 16) == 0 else {
            let code = errno; Darwin.close(fd); unlink(path.path); throw SocketError.system("listen", code)
        }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptConnection() } }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        guard listener >= 0 else { return }
        source?.cancel()
        source = nil
        listener = -1
        var file = stat()
        if let boundFile, stat(path.path, &file) == 0, file.st_dev == boundFile.device, file.st_ino == boundFile.inode {
            unlink(path.path)
        }
        boundFile = nil
    }

    private func acceptConnection() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            Self.logger.error("refused an agent connection from another user")
            Darwin.close(fd)
            return
        }
        // A client that stops reading fails the write after this, instead of holding the write queue for good.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        onConnection(AgentConnection(fd: fd))
    }
}

/// One client of the agent socket: reads whole lines, writes JSON lines.
@MainActor
final class AgentConnection {
    /// Requests are small JSON: file contents travel as paths, never inline.
    static let maxMessageBytes = 4 * 1024 * 1024
    /// Replies queued for a client that reads slower than Lilo answers, past which the connection closes.
    static let maxPendingBytes = 64 * 1024 * 1024

    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private(set) var isClosed = false
    private let fd: Int32
    /// The client process, spared by the lid-closed app freezer: an agent driving Lilo keeps running.
    let peerPID: pid_t
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    private var pendingBytes = 0
    /// Writes block on a slow reader, so they leave the main thread; closing goes through the same
    /// queue so the descriptor is never reused under a pending write.
    private let writeQueue = DispatchQueue(label: "fr.arouillard.lilo.agent-write")
    /// Only touched on writeQueue: after a failed write the stream holds a partial line, so nothing more is sent.
    nonisolated(unsafe) private var writeFailed = false

    init(fd: Int32) {
        self.fd = fd
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        peerPID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : 0
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        // Replies already queued go out first; a client that stopped reading hits the send timeout instead.
        source.setCancelHandler { [writeQueue] in writeQueue.async { _ = Darwin.close(fd) } }
        source.resume()
        self.source = source
    }

    /// `message` as the newline-terminated JSON `send` takes; heavy replies are encoded off the main thread.
    nonisolated static func line(_ message: [String: Any]) -> Data? {
        // A NaN or a date from a page script raises an exception that `try?` does not catch.
        guard JSONSerialization.isValidJSONObject(message), var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)
        return data
    }

    func send(_ line: Data) {
        guard !isClosed else { return }
        pendingBytes += line.count
        guard pendingBytes <= Self.maxPendingBytes else { close(); return }
        let fd = fd
        writeQueue.async { [self] in
            if !writeFailed {
                line.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            // The read side then sees EOF and closes the connection.
                            writeFailed = true
                            shutdown(fd, SHUT_RDWR)
                            return
                        }
                        offset += written
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.pendingBytes -= line.count } }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        source?.cancel()
        source = nil
        onClose?()
    }

    private func readAvailable() {
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { close(); return }
        // Only the new bytes can hold a newline: rescanning a large pending message would be quadratic.
        var searchFrom = buffer.count
        buffer.append(contentsOf: chunk[0..<count])
        var lineStart = 0
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            if newline > lineStart { onMessage?(Data(buffer[lineStart..<newline])) }
            if isClosed { return }
            lineStart = newline + 1
            searchFrom = lineStart
        }
        if lineStart > 0 { buffer.removeSubrange(0..<lineStart) }
        if buffer.count > Self.maxMessageBytes { close() }
    }
}
