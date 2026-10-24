import Foundation
import IOKit.pwr_mgt

/// chrome.power gap bridge. Like Chrome's single wake lock, one IOPM assertion serves every
/// extension's request at the strongest level asked; a request lasts until released, replaced or
/// its extension unloads.
@MainActor
final class PowerBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["power.requestKeepAwake", "power.releaseKeepAwake"]

    /// Requested level per "profileId/extensionId".
    private var levels: [String: String] = [:]
    nonisolated(unsafe) private var assertion: (id: IOPMAssertionID, level: String)?
    nonisolated(unsafe) private var unloadObserver: Any?

    init() {
        unloadObserver = NotificationCenter.default.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
            guard let profileId = note.userInfo?["profileId"] as? UUID, let extensionId = note.userInfo?["extensionId"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self, self.levels.removeValue(forKey: "\(profileId)/\(extensionId)") != nil else { return }
                self.updateAssertion()
            }
        }
    }

    deinit {
        unloadObserver.map { NotificationCenter.default.removeObserver($0) }
        assertion.map { _ = IOPMAssertionRelease($0.id) }
    }

    func handle(_ call: GapCall) async -> Any? {
        let key = "\(call.registry.profileId)/\(call.extensionId)"
        switch call.action {
        case "power.requestKeepAwake":
            levels[key] = call.string("level") == "display" ? "display" : "system"
        case "power.releaseKeepAwake":
            levels[key] = nil
        default:
            return nil
        }
        updateAssertion()
        return nil
    }

    private func updateAssertion() {
        let level = levels.isEmpty ? nil : levels.values.contains("display") ? "display" : "system"
        guard level != assertion?.level else { return }
        if let held = assertion {
            IOPMAssertionRelease(held.id)
            assertion = nil
        }
        guard let level else { return }
        // Chrome's wake lock types on macOS: kPreventAppSuspension is no idle sleep, kPreventDisplaySleep no display sleep.
        let type = level == "display" ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Extension keep-awake request" as CFString, &id) == kIOReturnSuccess {
            assertion = (id, level)
        }
    }
}
