import Foundation
import MetricKit

/// Keeps the hang, CPU and disk-write diagnostics macOS delivers about Lilo (with call stacks) and
/// the latest daily metrics, on this Mac only, for the next recorded performance session.
final class MetricKitArchive: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitArchive()
    private static let keptDiagnostics = 14

    private static var directory: URL {
        URL(fileURLWithPath: BuildIdentity.appSupportDirectory).appendingPathComponent("Diagnostics/MetricKit", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Self.write(payload.jsonRepresentation(), name: "diagnostic-\(Int(payload.timeStampEnd.timeIntervalSince1970)).json")
        }
        let diagnostics = Self.files().filter { $0.lastPathComponent.hasPrefix("diagnostic-") }
        for file in diagnostics.dropLast(Self.keptDiagnostics) { try? FileManager.default.removeItem(at: file) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        if let latest = payloads.max(by: { $0.timeStampEnd < $1.timeStampEnd }) {
            Self.write(latest.jsonRepresentation(), name: "metrics.json")
        }
    }

    /// The archived payloads as one JSON array, oldest first, or nil when there are none.
    static func storedPayloadsJSON() -> Data? {
        let payloads = files().compactMap { try? Data(contentsOf: $0) }
        guard !payloads.isEmpty else { return nil }
        var out = Data("[".utf8)
        for (index, payload) in payloads.enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(payload)
        }
        out.append(UInt8(ascii: "]"))
        return out
    }

    /// Sorted by name, which sorts diagnostics by date.
    private static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func write(_ data: Data, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
