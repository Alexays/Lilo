import CoreGraphics
import Foundation
import ImageIO

/// Favicon encoding, dominant-color analysis, and LRU cache.
@MainActor
final class FaviconService {

    // MARK: - Config

    private static let ttl: TimeInterval = 4 * 3600  // 4 hours
    /// How often an unchanged favicon still in use rewrites its store row: the store's cap evicts by age.
    private static let persistInterval: TimeInterval = 24 * 3600
    // Matches FaviconStore.maxRows so a full warm from disk fits without evictions.
    private static let cacheCapacity = FaviconStore.maxRows

    // MARK: - State

    private struct Cache<Key: Hashable, Value> {
        private var storage: [Key: Node] = [:]
        private var head: Node?
        private var tail: Node?
        private let capacity: Int

        private final class Node {
            let key: Key
            var value: Value
            var prev: Node?
            var next: Node?

            init(key: Key, value: Value) {
                self.key = key
                self.value = value
            }
        }

        init(capacity: Int) {
            precondition(capacity > 0)
            self.capacity = capacity
            storage.reserveCapacity(capacity)
        }

        mutating func get(_ key: Key) -> Value? {
            guard let node = storage[key] else { return nil }
            moveToHead(node)
            return node.value
        }

        mutating func set(_ key: Key, _ value: Value) {
            if let node = storage[key] {
                node.value = value
                moveToHead(node)
                return
            }

            let node = Node(key: key, value: value)
            storage[key] = node
            addToHead(node)
            if storage.count > capacity {
                removeTail()
            }
        }

        @discardableResult
        mutating func remove(_ key: Key) -> Value? {
            guard let node = storage.removeValue(forKey: key) else { return nil }
            unlink(node)
            return node.value
        }

        private mutating func addToHead(_ node: Node) {
            node.prev = nil
            node.next = head
            head?.prev = node
            head = node
            if tail == nil { tail = node }
        }

        private mutating func unlink(_ node: Node) {
            node.prev?.next = node.next
            node.next?.prev = node.prev
            if head === node { head = node.next }
            if tail === node { tail = node.prev }
            node.prev = nil
            node.next = nil
        }

        private mutating func moveToHead(_ node: Node) {
            guard head !== node else { return }
            unlink(node)
            addToHead(node)
        }

        private mutating func removeTail() {
            guard let tail else { return }
            storage.removeValue(forKey: tail.key)
            unlink(tail)
        }
    }

    private struct Entry {
        let dataURL: String
        let dominantColor: String?
        let expiresAt: Date
        /// When this process last wrote the icon to each profile's store; absent when it has not.
        var persistedAt: [UUID: Date]
        var isExpired: Bool { expiresAt < Date() }
    }

    /// A resolved favicon: the `data:` URL plus its precomputed dominant color.
    struct Resolved {
        let dataURL: String
        let dominantColor: String?
        /// Past its TTL: still shown, but due for a refetch.
        var isExpired = false
    }

    private var cache = Cache<String, Entry>(capacity: cacheCapacity)

    /// Durable backing for downloaded favicons, per profile. Writes go through the pool's writer
    /// queue, so seeding never blocks the main actor on SQLite.
    var storeForProfile: (UUID) -> FaviconStore? = { _ in nil }

    // MARK: - Cache

    func cached(for host: String) -> Resolved? {
        let key = host.lowercased()
        guard let entry = cache.get(key) else { return nil }
        return Resolved(dataURL: entry.dataURL, dominantColor: entry.dominantColor, isExpired: entry.isExpired)
    }

    func clear(for host: String) { cache.remove(host.lowercased()) }

    /// Persists into `profileId`'s store; nil (private browsing) keeps the icon in the in-memory cache only.
    /// A refetch that yields the cached icon only extends its TTL, and rewrites the row at most daily.
    func seed(host: String, dataURL: String, dominantColor: String?, profileId: UUID?) {
        let key = host.lowercased()
        let now = Date()
        let previous = cache.get(key).flatMap { $0.dataURL == dataURL && $0.dominantColor == dominantColor ? $0 : nil }
        var persistedAt = previous?.persistedAt ?? [:]
        let persists = profileId.map { now.timeIntervalSince(persistedAt[$0] ?? .distantPast) >= Self.persistInterval } ?? false
        if persists, let profileId { persistedAt[profileId] = now }
        cache.set(key, Entry(dataURL: dataURL, dominantColor: dominantColor, expiresAt: now.addingTimeInterval(Self.ttl), persistedAt: persistedAt))
        guard persists, let profileId else { return }
        storeForProfile(profileId)?.upsertManyAsync([FaviconStore.Entry(host: host, dataURL: dataURL, dominantColor: dominantColor)])
    }

    /// Writes a cached icon into `profileId`'s store the first time this process serves it there:
    /// the cache is shared by every profile, so another profile may have fetched it.
    func persistCachedIfUnwritten(host: String, profileId: UUID) {
        let key = host.lowercased()
        guard var entry = cache.get(key), entry.persistedAt[profileId] == nil else { return }
        entry.persistedAt[profileId] = Date()
        cache.set(key, entry)
        storeForProfile(profileId)?.upsertManyAsync([FaviconStore.Entry(host: key, dataURL: entry.dataURL, dominantColor: entry.dominantColor)])
    }

    /// Cache warming from already-known favicons (e.g. restored tabs). Won't clobber a live entry.
    func warmIfAbsent(host: String, dataURL: String, dominantColor: String?) {
        let key = host.lowercased()
        guard !dataURL.isEmpty, cache.get(key) == nil else { return }
        cache.set(key, Entry(dataURL: dataURL, dominantColor: dominantColor, expiresAt: Date().addingTimeInterval(Self.ttl), persistedAt: [:]))
    }

    /// Restore-path favicon fill. Blobs carry no favicon data URLs, so absent ones are filled from
    /// the cache by host. Hosts the cache misses are read from `store` first, so the restore needs
    /// no warm of the whole table.
    func rehydrateRestoredTabs(_ tabs: inout [Tab], store: FaviconStore? = nil) {
        if let store {
            var missingHosts = Set<String>()
            for tab in tabs {
                if tab.faviconDataURL?.isEmpty ?? true, let host = tab.url?.host?.lowercased(), cache.get(host) == nil {
                    missingHosts.insert(host)
                }
                if tab.homeFaviconDataURL?.isEmpty ?? true, let host = tab.homeURL?.host?.lowercased(), cache.get(host) == nil {
                    missingHosts.insert(host)
                }
            }
            for entry in (try? store.entries(forHosts: missingHosts)) ?? [] {
                warmIfAbsent(host: entry.host, dataURL: entry.dataURL, dominantColor: entry.dominantColor)
            }
        }

        func rehydrate(host rawHost: String?, dataURL: inout String?, dominantColor: inout String?) {
            guard dataURL?.isEmpty ?? true, let host = rawHost?.lowercased(), let cached = cached(for: host) else { return }
            dataURL = cached.dataURL
            if dominantColor == nil { dominantColor = cached.dominantColor }
        }

        for index in tabs.indices {
            var tab = tabs[index]
            rehydrate(host: tab.url?.host, dataURL: &tab.faviconDataURL, dominantColor: &tab.faviconDominantColor)
            rehydrate(host: tab.homeURL?.host, dataURL: &tab.homeFaviconDataURL, dominantColor: &tab.homeFaviconDominantColor)
            tabs[index] = tab
        }
    }

    // MARK: - Encoding

    /// Target favicon size in pixels. Icons larger than this are downscaled at extraction
    /// so full-size raster favicons (up to ~13KB) don't get embedded in every tab payload/session blob.
    nonisolated static let maxFaviconPixels = 32
    /// SVG icons are kept as is, so their bytes are capped instead: every tab payload embeds them.
    nonisolated static let maxSVGFaviconBytes = 16 * 1024

    /// Bytes WebKit loaded for a link icon. Its declared type is the page's word, so the bytes decide:
    /// rasters become a downscaled PNG, SVG stays as is up to `maxSVGFaviconBytes`, anything else
    /// (a soft-404 page, an oversized SVG) is rejected so the next link icon is tried.
    nonisolated static func encodedFavicon(data: Data) -> (dataURL: String, png: Data?)? {
        if let png = downscaledPNG(data: data, maxPixels: maxFaviconPixels) {
            return ("data:image/png;base64," + png.base64EncodedString(), png)
        }
        guard data.count <= maxSVGFaviconBytes,
              let head = String(data: data.prefix(1024), encoding: .utf8)?.lowercased(), head.contains("<svg") else { return nil }
        return ("data:image/svg+xml;base64," + data.base64EncodedString(), nil)
    }

    /// Decodes `data` and, if its largest dimension exceeds `maxPixels`, returns a PNG re-encoding
    /// downscaled to fit `maxPixels` (aspect preserved, never upscaled). Returns `nil` if the image
    /// can't be decoded/re-encoded, so callers can fall back to the original bytes.
    nonisolated static func downscaledPNG(data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Thumbnail honors the max pixel size and aspect ratio and won't upscale a smaller icon.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    // MARK: - Dominant Color

    /// Returns the most visually prominent color from a base64 `data:image/...` URL as a hex string.
    /// Downsamples to 8×8 and picks the pixel with the highest HSV saturation.
    /// Falls back to the darkest non-white pixel for achromatic icons (GitHub, etc.).
    nonisolated static func dominantColor(from dataURL: String) -> String? {
        guard dataURL.hasPrefix("data:image/"),
              let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let imageData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }

        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        // Multi-resolution sources (.ico etc.) carry many frames; read dimensions from the
        // properties (no decode) and decode only the winning frame.
        var bestIndex = 0
        var bestArea = 0
        for i in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
                  let width = properties["PixelWidth"] as? Int,
                  let height = properties["PixelHeight"] as? Int else { continue }
            let area = width * height
            if area > bestArea { bestArea = area; bestIndex = i }
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, bestIndex, nil) else { return nil }
        return dominantColor(of: cgImage)
    }

    /// Same as `dominantColor(from:)` for PNG bytes already in hand (the downscaled favicon):
    /// skips the base64 decode and the multi-index scan (the thumbnail is single-image).
    nonisolated static func dominantColor(fromPNG data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return dominantColor(of: cgImage)
    }

    private nonisolated static func dominantColor(of cgImage: CGImage) -> String? {
        guard let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Composite on white so transparent icons produce visible pixels to sample.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))

        guard let pixelData = context.data else { return nil }
        let pixels = pixelData.bindMemory(to: UInt8.self, capacity: 8 * 8 * 4)

        var bestSat: CGFloat = 0
        var bestR: UInt8 = 0, bestG: UInt8 = 0, bestB: UInt8 = 0

        for i in 0..<64 {
            let o = i * 4
            let a = pixels[o + 3]
            guard a > 20 else { continue }
            let af = CGFloat(a) / 255.0
            let r = min(CGFloat(pixels[o]) / 255.0 / af, 1.0)
            let g = min(CGFloat(pixels[o + 1]) / 255.0 / af, 1.0)
            let b = min(CGFloat(pixels[o + 2]) / 255.0 / af, 1.0)
            let maxC = max(r, g, b), minC = min(r, g, b)
            let sat = maxC == 0 ? 0 : (maxC - minC) / maxC
            if sat > bestSat { bestSat = sat; bestR = UInt8(r * 255); bestG = UInt8(g * 255); bestB = UInt8(b * 255) }
        }

        if bestSat > 0.12 {
            return String(format: "#%02X%02X%02X", bestR, bestG, bestB)
        }

        // Achromatic fallback: darkest non-near-white pixel
        var bestDist: CGFloat = -1
        var fbR: UInt8 = 0, fbG: UInt8 = 0, fbB: UInt8 = 0
        for i in 0..<64 {
            let o = i * 4
            let r = CGFloat(pixels[o]) / 255.0
            let g = CGFloat(pixels[o + 1]) / 255.0
            let b = CGFloat(pixels[o + 2]) / 255.0
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            guard lum < 0.85 else { continue }
            let dist = abs(lum - 0.5)
            if dist > bestDist { bestDist = dist; fbR = UInt8(r * 255); fbG = UInt8(g * 255); fbB = UInt8(b * 255) }
        }
        guard bestDist >= 0 else { return nil }
        return String(format: "#%02X%02X%02X", fbR, fbG, fbB)
    }
}
