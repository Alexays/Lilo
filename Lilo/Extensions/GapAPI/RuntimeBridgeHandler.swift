/// The `chrome.runtime` calls WebKit lacks: `requestUpdateCheck`, against Lilo's update checker; and
/// whether the worker listens to `runtime.onMessage`, which picks Chrome's error for a page's message
/// nobody answers (a worker that has not reported its listeners yet counts as listening).
@MainActor
final class RuntimeBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["runtime.requestUpdateCheck", "runtime.workerListensToMessages"]

    func handle(_ call: GapCall) async -> Any? {
        if call.action == "runtime.workerListensToMessages" {
            return call.registry.gapEvents.reportedListeners(of: call.extensionId)?.contains("runtime.onMessage") ?? true
        }
        return await call.registry.updater.requestUpdateCheck(extensionId: call.extensionId)
    }
}
