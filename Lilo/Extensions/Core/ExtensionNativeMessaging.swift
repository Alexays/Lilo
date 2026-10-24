import WebKit

/// Native messaging for extensions: `chrome.runtime.sendNativeMessage` and the ports
/// `chrome.runtime.connectNative` opens, each relayed to the host process it launches.
@MainActor
final class ExtensionNativeMessaging {
    /// What chrome.runtime.connectNative (chrome-leniency.ts) appends to the host name, sends first on
    /// the port, and reads Lilo's error under.
    static let portMark = "?lilo"
    static let portOpenedKey = "liloNativePortOpened"
    static let portErrorKey = "liloNativePortError"

    /// The ports whose host runs, retained until it disconnects (releasing would disconnect the host).
    private var hostedPorts: [ObjectIdentifier: NativePort] = [:]

    func send(
        _ message: Any,
        toHost hostName: String?,
        for context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        guard let hostName else {
            replyHandler(nil, ExtensionControllerDelegate.extensionError("No native messaging application specified")); return
        }
        // NativeMessaging replies on the main queue, where WebKit expects the handler.
        nonisolated(unsafe) let replyHandler = replyHandler
        NativeMessaging.sendOneShot(
            hostName: hostName,
            message: message,
            extensionOrigin: "chrome-extension://\(context.uniqueIdentifier)/",
            extensionId: context.uniqueIdentifier
        ) { result in
            switch result {
            case .success(let reply): replyHandler(reply, nil)
            case .failure(let error): replyHandler(nil, error)
            }
        }
    }

    func connect(
        _ port: WKWebExtension.MessagePort,
        toHost hostName: String,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Chrome disconnects a refused port with the error as lastError, WebKit records an extension error: the port opens
        // anyway and fails on its first message, once its listeners are registered; a marked port also carries the error.
        var hostName = hostName
        let isMarked = hostName.hasSuffix(Self.portMark)
        if isMarked { hostName.removeLast(Self.portMark.count) }
        let nativePort = NativePort(port, isMarked: isMarked)
        do {
            nativePort.connection = try NativeMessaging.connect(
                hostName: hostName,
                extensionId: context.uniqueIdentifier,
                extensionOrigin: "chrome-extension://\(context.uniqueIdentifier)/",
                onMessage: { [weak port] message in
                    MainActor.assumeIsolated { port?.sendMessage(message, completionHandler: nil) }
                },
                // Weak: the port holds the connection, which holds this closure.
                onDisconnect: { [weak self, weak nativePort] error in
                    MainActor.assumeIsolated {
                        guard let nativePort else { return }
                        if let error { nativePort.fail(error.localizedDescription) } else { nativePort.port?.disconnect() }
                        nativePort.connection = nil
                        self?.hostedPorts[ObjectIdentifier(nativePort)] = nil
                    }
                }
            )
            hostedPorts[ObjectIdentifier(nativePort)] = nativePort
        } catch {
            nativePort.pendingError = error.localizedDescription
        }
        port.messageHandler = { message, _ in nativePort.receive(message) }
        port.disconnectHandler = { [weak nativePort] _ in nativePort?.connection?.disconnect() }
        completionHandler(nil)
    }
}

/// A connectNative port and its host. WebKit drops what Lilo sends on the port before the port's
/// first message arrives, so an error until then waits for that message.
@MainActor
private final class NativePort {
    weak var port: WKWebExtension.MessagePort?
    var connection: NativeMessagingConnection?
    var pendingError: String?
    private let isMarked: Bool
    private var isOpen: Bool

    init(_ port: WKWebExtension.MessagePort, isMarked: Bool) {
        self.port = port
        self.isMarked = isMarked
        isOpen = !isMarked
    }

    func receive(_ message: Any?) {
        let isOpening = !isOpen && (message as? [String: Any])?[ExtensionNativeMessaging.portOpenedKey] != nil
        isOpen = true
        if let pendingError { return fail(pendingError) }
        if !isOpening, let message { connection?.send(message) }
    }

    func fail(_ message: String) {
        guard isOpen else { pendingError = message; return }
        if isMarked { port?.sendMessage([ExtensionNativeMessaging.portErrorKey: message], completionHandler: nil) }
        port?.disconnect()
    }
}
