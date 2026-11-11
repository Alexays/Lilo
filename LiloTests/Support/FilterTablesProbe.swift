import WebKit
@testable import Lilo

extension WKUserContentController {
    /// The filter scripts with their tables: read from the bridge world's buffers where WebKit keeps them out of the sources.
    @MainActor
    func test_filterSources() async -> String {
        var sources = userScripts.map(\.source).joined(separator: "\n")
        if #available(macOS 27.0, *) {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = self
            let buffers = try? await WKWebView(frame: .zero, configuration: configuration).callAsyncJavaScript(
                "return ['liloGenericCosmetics', 'liloProcedural', 'liloScriptlets'].map(name => webkit.buffers?.[name]?.asLatin1String() ?? '').join('\\n')",
                contentWorld: PageWorld.bridgeWorld
            )
            sources += buffers as? String ?? ""
        }
        return sources
    }
}
