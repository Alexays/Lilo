import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure helpers for moving PNG bytes across the screenshot bridge. No AppKit, no disk I/O:
/// `fileExists` is injected so the unique-name logic is unit-testable.
enum ScreenshotImageCodec {

    /// Decodes a PNG data URL (`data:image/png;base64,<...>`) or a bare base64 string into raw bytes.
    static func decodePNGDataURL(_ dataURL: String) -> Data? {
        let base64: Substring
        if let commaIndex = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:") {
            base64 = dataURL[dataURL.index(after: commaIndex)...]
        } else {
            base64 = Substring(dataURL)
        }
        return Data(base64Encoded: String(base64))
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// `png` cut to `rect`, in image pixels from the top-left and clamped to the image. The original
    /// bytes when the crop covers the whole image; nil when it covers none of it.
    static func croppedPNG(_ png: Data, to rect: CGRect) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = rect.standardized.integral.intersection(bounds)
        guard !crop.isEmpty else { return nil }
        if crop == bounds { return png }
        return image.cropping(to: crop).flatMap(pngData)
    }

    /// Returns `folder/filename`, appending ` (2)`, ` (3)`, ... before the extension until the name is
    /// free according to `fileExists`.
    static func uniqueURL(in folder: URL, filename: String, fileExists: (URL) -> Bool) -> URL {
        let candidate = folder.appendingPathComponent(filename)
        guard fileExists(candidate) else { return candidate }

        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            let next = folder.appendingPathComponent(name)
            if !fileExists(next) { return next }
            counter += 1
        }
    }
}
