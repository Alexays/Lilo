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
        // A fixed scheme and a UUID always parse.
        // swiftlint:disable:next force_unwrapping
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
            serveReleaseMedia(path: path, task: urlSchemeTask, url: url)
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
        let data = unsafe Data(
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

    private func serveReleaseMedia(path: String, task: WKURLSchemeTask, url: URL) {
        guard path.range(of: #"^release-media/[0-9]+\.[0-9]+\.[0-9]+/[a-z0-9-]+\.(png|mp4)$"#, options: .regularExpression) != nil else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let parts = path.split(separator: "/")
        guard let file = Bundle.main.url(forResource: String(parts[2]), withExtension: nil, subdirectory: "release-media/\(parts[1])"),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let requested = task.request.value(forHTTPHeaderField: "Range")
        let range = Self.mediaByteRange(requested, length: data.count)
        var headers = ["Content-Type": path.hasSuffix(".mp4") ? "video/mp4" : "image/png", "Accept-Ranges": "bytes"]
        let status: Int
        if let range {
            status = requested == nil ? 200 : 206
            headers["Content-Length"] = String(range.count)
            if requested != nil { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)" }
        } else {
            status = 416
            headers["Content-Length"] = "0"
            headers["Content-Range"] = "bytes */\(data.count)"
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse)); return
        }
        task.didReceive(response)
        if let range { task.didReceive(data.subdata(in: range)) }
        task.didFinish()
    }

    /// WebKit asks for byte ranges to inspect and seek an MP4 without loading the whole film.
    static func mediaByteRange(_ header: String?, length: Int) -> Range<Int>? {
        guard length > 0 else { return nil }
        guard let header else { return 0..<length }
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start >= 0, start < length else { return nil }
        if parts[1].isEmpty { return start..<length }
        guard let end = Int(parts[1]), end >= start else { return nil }
        return start..<(min(end, length - 1) + 1)
    }

    /// The Finder icon for `file-icon/<extension>`, rendered once per extension.
    private static func fileIconPNG(path: String) -> Data {
        if let cached = dataByPath[path] { return cached }
        let ext = String(path.dropFirst(fileIconPrefix.count)).removingPercentEncoding?.lowercased() ?? ""
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        let rect = NSRect(x: 0, y: 0, width: fileIconPointSize, height: fileIconPointSize)
        let data = icon.bestRepresentation(for: rect, context: nil, hints: nil)
            .flatMap { unsafe $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
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
