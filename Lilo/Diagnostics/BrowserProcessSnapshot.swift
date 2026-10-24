import Foundation

/// Declaration order is the Process Manager's display order.
enum BrowserProcessKind: String, Sendable, CaseIterable {
    case webContent
    case provisionalWebContent
    case network
    case gpu
    case model
}

struct WebViewProcessDiagnostics: Sendable, Equatable {
    var webProcessIdentifier: Int?
    var provisionalWebProcessIdentifier: Int?
    var networkProcessIdentifier: Int?
    var gpuProcessIdentifier: Int?
    var modelProcessIdentifier: Int?
    var webProcessIsResponsive: Bool?
    var webProcessState: Int?
    var isPictureInPictureActive: Bool?
    var committedURL: String?
    var mainFrameURL: String?
}

struct BrowserProcessTabInfo: Sendable, Equatable {
    var id: UUID
    var spaceId: UUID
    var title: String
    var url: String
    var lifecycle: String
    var isActiveSpace: Bool
    var isActiveTab: Bool
    var isAudioPlaying: Bool
    var isMicrophoneActive: Bool
    var isCameraActive: Bool
    var isScreenSharing: Bool
    var isPictureInPictureActive: Bool?

    var bridgeData: [String: Any] {
        [
            "id": id.uuidString,
            "spaceId": spaceId.uuidString,
            "title": title,
            "url": url,
            "lifecycle": lifecycle,
            "isAudioPlaying": isAudioPlaying,
            "isMicrophoneActive": isMicrophoneActive,
            "isCameraActive": isCameraActive,
            "isScreenSharing": isScreenSharing,
            "isPictureInPictureActive": isPictureInPictureActive as Any
        ]
    }
}

struct ProcessResourceMetrics: Sendable, Equatable {
    var residentSizeBytes: UInt64
    var cpuPercent: Double?
}

struct BrowserProcessInfo: Sendable, Equatable {
    var kind: BrowserProcessKind
    var pid: Int
    var tabs: [BrowserProcessTabInfo] = []
    var metrics: ProcessResourceMetrics?
    var webProcessState: Int?
    var webProcessIsResponsive: Bool?

    var id: String { "\(kind.rawValue)-\(pid)" }

    var bridgeData: [String: Any] {
        [
            "id": id,
            "kind": kind.rawValue,
            "pid": pid,
            "tabs": tabs.map(\.bridgeData),
            "metrics": metrics.map { ["residentSizeBytes": Double($0.residentSizeBytes), "cpuPercent": $0.cpuPercent as Any] } as Any,
            "webProcessStateLabel": webProcessState.map { "state-\($0)" } ?? "unknown",
            "webProcessIsResponsive": webProcessIsResponsive as Any
        ]
    }
}
