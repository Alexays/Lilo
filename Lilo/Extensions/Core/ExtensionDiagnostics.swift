import Foundation
import WebKit
import os

enum ExtensionDiagnostics {
    /// Whether the errors show a background that failed to load, the one class a reload can fix. A
    /// script error thrown by a running worker (WebKit records every uncaught one) or a missing package
    /// asset repeats on every start, so reviving on it only churns and degrades a working extension.
    static func errorsWarrantBackgroundRevive(_ errors: some Collection<any Error>) -> Bool {
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

    /// Logs `errors`, a tail of the context's cumulative `errors`, keeping each one's index in the full list.
    @MainActor
    static func logContextErrorsIfNeeded(
        _ errors: ArraySlice<any Error>,
        of context: WKWebExtensionContext,
        extensionId: String,
        reason: String,
        logger: Logger
    ) {
        guard !errors.isEmpty else { return }
        let name = context.webExtension.displayName ?? ""
        let label = name.isEmpty ? extensionId : "\(name) (\(extensionId))"
        logger.error("WKWebExtensionContext errors for \(label, privacy: .public) reason=\(reason, privacy: .public) new=\(errors.count, privacy: .public) count=\(errors.endIndex, privacy: .public)")
        for (index, error) in zip(errors.indices, errors) {
            logger.error("WKWebExtensionContext error[\(index, privacy: .public)] for \(label, privacy: .public): \(diagnosticDescription(for: error), privacy: .public)")
        }
    }
}
