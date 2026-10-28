import AppKit
import UniformTypeIdentifiers
import WebKit

/// Serves the chrome UI bundle compiled into the binary over the app-private `lilo-chrome://` scheme, so WebKit loads it as a normal origin.
/// Registered only on the chrome web view's configuration: content web views cannot resolve the scheme.
final class ChromeUISchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lilo-chrome"
    static let indexURL = URL(string: "lilo-chrome://ui/index.html")!

    /// Rendered file-type icons, by path.
    private static var dataByPath: [String: Data] = [:]
    private static let fileIconPrefix = "file-icon/"
    private static let fileIconPointSize: CGFloat = 64
    private static let screenshotPrefix = "screenshot/"
    /// Bundle resources rather than embedded assets: the embed is text only.
    private static let passwordManagerPrefix = "password-managers/"
    /// Captures open in the screenshot editor, by id. Served from the chrome's own origin rather
    /// than as data URLs: a full-page PNG runs to tens of megabytes, and a same-origin image keeps
    /// the editor's export canvas untainted.
    private static var screenshots: [String: Data] = [:]

    /// Holds `png` until `discardScreenshot(id:)` and returns the URL the editor loads it from.
    static func publishScreenshot(_ png: Data) -> (id: String, url: URL) {
        let id = UUID().uuidString
        screenshots[id] = png
        return (id, URL(string: "lilo-chrome://ui/\(screenshotPrefix)\(id).png")!)
    }

    static func screenshot(id: String) -> Data? { screenshots[id] }

    static func discardScreenshot(id: String) { screenshots[id] = nil }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let path = Self.assetPath(for: url)
        if path.hasPrefix("release-media/") {
            let name = (path as NSString).lastPathComponent
            guard path == "release-media/\(name)",
                  name.range(of: "^[a-z][a-z0-9-]{0,47}-native\\.(png|webp)$", options: .regularExpression) != nil,
                  let file = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "release-media"),
                  let data = try? Data(contentsOf: file) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: name.hasSuffix(".webp") ? "image/webp" : "image/png", expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }
        if path.hasPrefix(Self.fileIconPrefix) {
            let data = Self.fileIconPNG(path: path)
            urlSchemeTask.didReceive(URLResponse(
                url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil
            ))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }
        if path.hasPrefix(Self.screenshotPrefix) {
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let data = Self.screenshots[id]
            var headers = ["Content-Type": "image/png", "Content-Length": String(data?.count ?? 0)]
            #if DEBUG
            // The dev-server chrome is another origin, and its export canvas must stay readable.
            headers["Access-Control-Allow-Origin"] = "*"
            #endif
            guard let data, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }
        if path.hasPrefix(Self.passwordManagerPrefix) {
            let name = (path as NSString).lastPathComponent
            guard let file = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "password-managers"),
                  let data = try? Data(contentsOf: file) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            urlSchemeTask.didReceive(URLResponse(
                url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil
            ))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }
        if path == "index.html" || path == "index.js" { StartupMetrics.markOnce("chromeServed:\(path)") }
        guard let asset = ChromeUIAssets.assets[path] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // The literal lives in the binary for the process lifetime, so Data can borrow it.
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: asset.text.utf8Start),
            count: asset.text.utf8CodeUnitCount,
            deallocator: .none
        )
        // Fetch sees a plain custom-scheme response as status 0, so local JSON needs an explicit success status.
        let response: URLResponse = if asset.mimeType == "application/json", let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json; charset=utf-8", "Content-Length": String(data.count)]
        ) {
            response
        } else {
            URLResponse(url: url, mimeType: asset.mimeType, expectedContentLength: data.count, textEncodingName: "utf-8")
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    /// The Finder icon for `file-icon/<extension>`, rendered once per extension.
    private static func fileIconPNG(path: String) -> Data {
        if let cached = dataByPath[path] { return cached }
        let ext = String(path.dropFirst(fileIconPrefix.count)).removingPercentEncoding?.lowercased() ?? ""
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        let rect = NSRect(x: 0, y: 0, width: fileIconPointSize, height: fileIconPointSize)
        let data = icon.bestRepresentation(for: rect, context: nil, hints: nil)
            .flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
            ?? Data()
        dataByPath[path] = data
        return data
    }

    /// Maps a lilo-chrome:// URL to its embedded-asset key ("" and "/" resolve to index.html).
    static func assetPath(for url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path.isEmpty ? "index.html" : path
    }
}
