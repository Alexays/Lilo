import CoreServices
import Foundation

/// Calls `onChange` (on the main queue, coalesced) when anything under `folder` changes, so a
/// plugin whose behavior is authored as files reloads without polling: FSEvents costs nothing
/// while the folder is quiet.
@safe final class PluginFolderWatcher {
    private final class Box {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let box: Box

    init?(folder: URL, latency: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        box = Box(onChange)
        var context = unsafe FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = unsafe info else { return }
            unsafe Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = unsafe FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return nil }
        unsafe self.stream = stream
        unsafe FSEventStreamSetDispatchQueue(stream, .main)
        unsafe FSEventStreamStart(stream)
    }

    deinit {
        guard let stream = unsafe stream else { return }
        unsafe FSEventStreamStop(stream)
        unsafe FSEventStreamInvalidate(stream)
        unsafe FSEventStreamRelease(stream)
    }
}
