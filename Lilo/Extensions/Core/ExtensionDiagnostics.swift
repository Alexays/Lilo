import Foundation
import WebKit
import os

enum ExtensionDiagnostics {
    /// Whether the errors show a background that failed to load, the one class a reload can fix. A
    /// script error thrown by a running worker (WebKit records every uncaught one) or a missing package
    /// asset repeats on every start, so reviving on it only churns and degrades a working extension.
    static func errorsWarrantBackgroundRevive(_ errors: [any Error]) -> Bool {
        errors.contains { error in
            let nsError = error as NSError
            return nsError.domain == WKWebExtensionContext.errorDomain
                && nsError.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
        }
    }

    static func diagnosticDescription(for error: Error) -> String {
        let nsError = error as NSError
        let userInfo = nsError.userInfo
            .map { key, value in "\(key)=\(String(describing: value))" }
            .sorted()
            .joined(separator: ", ")
        let suffix = userInfo.isEmpty ? "" : " userInfo={\(userInfo)}"
        return "message=\"\(nsError.localizedDescription)\" domain=\(nsError.domain) code=\(nsError.code)\(suffix)"
    }

    @MainActor
    static func logContextErrorsIfNeeded(
        _ context: WKWebExtensionContext,
        extensionId: String,
        reason: String,
        logger: Logger
    ) {
        let errors = context.errors
        guard !errors.isEmpty else { return }
        let name = context.webExtension.displayName ?? ""
        let label = name.isEmpty ? extensionId : "\(name) (\(extensionId))"
        logger.error("WKWebExtensionContext errors for \(label, privacy: .public) reason=\(reason, privacy: .public) count=\(errors.count, privacy: .public)")
        for (index, error) in errors.enumerated() {
            logger.error("WKWebExtensionContext error[\(index, privacy: .public)] for \(label, privacy: .public): \(diagnosticDescription(for: error), privacy: .public)")
        }
    }
}
