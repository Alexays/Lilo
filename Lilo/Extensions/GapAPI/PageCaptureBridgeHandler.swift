import WebKit

/// `chrome.pageCapture.saveAsMHTML`: the tab's WebKit web archive, of its live document as Chrome's MHTML is,
/// written out as MHTML with the header fields Chrome writes. The tab arrives as `{windowPosition, index}`.
@MainActor
final class PageCaptureBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["pageCapture.saveAsMHTML"]

    func handle(_ call: GapCall) async -> Any? {
        let registry = call.registry
        guard let context = call.context,
              let position = call.payload["tab"] as? [String: Any],
              let adapter = registry.tabAdapters(atPositions: [position], extensionId: call.extensionId).first ?? nil else {
            return BridgeError("Cannot find the tab for this request.")
        }
        guard let webView = adapter.webView(for: context), let url = webView.url else { return BridgeError("Failed to generate MHTML.") }
        // As Chrome: the permission is enough for a web page but the store's, and an extension may capture its own pages.
        let webPage = (url.scheme == "http" || url.scheme == "https") && !ChromeMasquerade.isStoreURL(url)
        guard webPage || (url.scheme == context.baseURL.scheme && url.host == context.baseURL.host) else {
            return BridgeError("Don't have permissions required to capture this page.")
        }
        let archive = await withCheckedContinuation { continuation in
            webView.createWebArchiveData { continuation.resume(returning: try? $0.get()) }
        }
        guard let archive,
              let root = (try? PropertyListSerialization.propertyList(from: archive, format: nil)) as? [String: Any],
              let mhtml = Self.mhtml(root, url: url, title: webView.title ?? "") else {
            return BridgeError("Failed to generate MHTML.")
        }
        return mhtml
    }

    /// The archive's main resource, then its subresources and frames, each URL once. Text parts are
    /// quoted-printable and the others base64, as Chrome writes them, so the document is ASCII.
    private static func mhtml(_ root: [String: Any], url: URL, title: String) -> String? {
        let boundary = "----MultipartBoundary--\(UUID().uuidString)----"
        var parts: [String] = []
        var seen: Set<String> = []
        func add(_ resource: [String: Any]?) {
            guard let resource, let data = resource["WebResourceData"] as? Data, let location = resource["WebResourceURL"] as? String,
                  seen.insert(location).inserted else { return }
            let type = resource["WebResourceMIMEType"] as? String ?? "application/octet-stream"
            let text = type.hasPrefix("text/")
            let charset = text ? (resource["WebResourceTextEncodingName"] as? String).map { "; charset=\($0)" } ?? "" : ""
            parts.append([
                "--\(boundary)",
                "Content-Type: \(type)\(charset)",
                "Content-Transfer-Encoding: \(text ? "quoted-printable" : "base64")",
                "Content-Location: \(location)",
                "",
                text ? quotedPrintable(data) : data.base64EncodedString(options: .lineLength76Characters)
            ].joined(separator: "\r\n"))
        }
        func addArchive(_ archive: [String: Any]) {
            add(archive["WebMainResource"] as? [String: Any])
            (archive["WebSubresources"] as? [[String: Any]])?.forEach(add)
            (archive["WebSubframeArchives"] as? [[String: Any]])?.forEach(addArchive)
        }
        addArchive(root)
        guard !parts.isEmpty else { return nil }
        let oneLine = title.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        let subject = oneLine.allSatisfy { $0.isASCII } ? oneLine : "=?utf-8?B?\(Data(oneLine.utf8).base64EncodedString())?="
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return ([
            "From: <Saved by Lilo>",
            "Snapshot-Content-Location: \(url.absoluteString)",
            "Subject: \(subject)",
            "Date: \(date.string(from: Date()))",
            "MIME-Version: 1.0",
            "Content-Type: multipart/related;",
            "\ttype=\"text/html\";",
            "\tboundary=\"\(boundary)\"",
            "",
            ""
        ] + parts + ["--\(boundary)--", ""]).joined(separator: "\r\n")
    }

    /// `data` in quoted-printable, its line breaks as CRLF and its lines wrapped at 76 characters.
    private static func quotedPrintable(_ data: Data) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 8)
        var column = 0
        let bytes = [UInt8](data)
        for (index, byte) in bytes.enumerated() {
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0x0A
            if byte == 0x0D && next == 0x0A { continue }
            if byte == 0x0A {
                out += [0x0D, 0x0A]
                column = 0
                continue
            }
            // A space or tab ending a line must be encoded, or a reader drops it.
            let literal = (byte >= 0x21 && byte <= 0x7E && byte != 0x3D) || ((byte == 0x20 || byte == 0x09) && next != 0x0A && next != 0x0D)
            let width = literal ? 1 : 3
            if column + width > 75 {
                out += [0x3D, 0x0D, 0x0A]
                column = 0
            }
            if literal {
                out.append(byte)
            } else {
                out += [0x3D, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            }
            column += width
        }
        // Every byte written is ASCII.
        return String(bytes: out, encoding: .ascii) ?? ""
    }
}
