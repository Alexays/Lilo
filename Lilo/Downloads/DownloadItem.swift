import Foundation
import GRDB

enum DownloadState: String, Codable {
    case inProgress, paused, complete, interrupted
}

struct DownloadItem: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "downloads"

    var id: Int64?
    var url: String
    var filename: String
    var destinationPath: String
    var bytesReceived: Int64
    var totalBytes: Int64       // -1 if unknown
    var state: DownloadState
    var error: String?
    var resumeData: Data?
    var startedAt: Date
    var endedAt: Date?
    var mimeType: String?
    var fileMissing: Bool
    var source: String = "wk"
    /// Set only by DownloadStore snapshot reads, which select `resumeData IS NOT NULL` in place of
    /// the blob; full-row reads leave it nil and `resumeData` itself answers.
    var hasResumeData: Bool?

    var canResume: Bool { state == .paused || hasResumeData ?? (resumeData != nil) }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// `hasResumeData` has no column, so the persisted columns are listed by hand.
    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["url"] = url
        container["filename"] = filename
        container["destinationPath"] = destinationPath
        container["bytesReceived"] = bytesReceived
        container["totalBytes"] = totalBytes
        container["state"] = state.rawValue
        container["error"] = error
        container["resumeData"] = resumeData
        container["startedAt"] = startedAt
        container["endedAt"] = endedAt
        container["mimeType"] = mimeType
        container["fileMissing"] = fileMissing
        container["source"] = source
    }

    // resumeData intentionally excluded: it is a URLSession-internal blob
    // used only by URLSessionBackend for pause/resume and must not cross the JS bridge.
    var bridgeData: [String: Any] {
        var data: [String: Any] = [
            "id": id ?? 0,
            "url": url,
            "filename": filename,
            "bytesReceived": bytesReceived,
            "totalBytes": totalBytes,
            "state": state.rawValue,
            "fileMissing": fileMissing,
            "source": source,
            "startedAt": startedAt.timeIntervalSince1970
        ]
        if let error { data["error"] = error }
        if let endedAt { data["endedAt"] = endedAt.timeIntervalSince1970 }
        return data
    }
}
