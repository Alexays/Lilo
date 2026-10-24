import AppKit
import os

/// Offers to move a Lilo run from its disk image, or translocated by Gatekeeper, into /Applications: there Sparkle
/// can replace it and the `lilo-mcp` path other apps were given points at the running app.
@MainActor
enum ApplicationsMover {
    private static let logger = Logger(liloCategory: "ApplicationsMover")

    /// True when Lilo is quitting to relaunch from Applications.
    static func offerMoveIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL
        let components = source.pathComponents
        let fromDiskImage = components.count > 2 && components[1] == "Volumes"
        guard fromDiskImage || source.path.contains("/AppTranslocation/") else { return false }

        let alert = NSAlert()
        alert.messageText = "Move Lilo to Applications?".localized
        alert.informativeText = "Lilo is running from the disk image. In Applications it gets its updates, and apps like Claude find it.".localized
        alert.addButton(withTitle: "Move to Applications".localized)
        alert.addButton(withTitle: "Not Now".localized)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        do {
            // A copy already there of this build or newer is kept: an old disk image never downgrades it.
            let installedBuild = Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let ownBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            if installedBuild.map({ $0.compare(ownBuild, options: .numeric) == .orderedAscending }) ?? true {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
            // Relaunches once this process is gone, so two copies never open the profile databases together.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = [
                "-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; [ -n "$2" ] && hdiutil detach -quiet "$2"; open "$3""#,
                "sh", String(getpid()), fromDiskImage ? "/" + components[1...2].joined(separator: "/") : "", destination.path
            ]
            try relaunch.run()
        } catch {
            logger.error("Moving to Applications failed: \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert()
            failure.messageText = "Lilo couldn't move itself to Applications".localized
            failure.informativeText = "Drag Lilo to the Applications folder in the Finder, then open it from there.".localized
            failure.runModal()
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}
