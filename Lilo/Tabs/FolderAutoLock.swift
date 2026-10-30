import AppKit
import CoreGraphics

/// Relocks every unlocked folder when the screen locks, the Mac sleeps, the session switches, or the
/// user has been idle for `folderAutoLockMinutes`. The idle timer only runs while a folder is unlocked.
@MainActor
final class FolderAutoLock {
    private unowned let context: BrowserContext
    private(set) var idleTimer: Timer?

    init(context: BrowserContext) {
        self.context = context
        // One BrowserContext lives as long as the app, so these observers are never removed.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockAll() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockAll() }
        }
    }

    func folderWasUnlocked() {
        guard idleTimer == nil else { return }
        lockIfIdle()
    }

    /// A new `folderAutoLockMinutes` applies to the folders already unlocked, at once if the user is idle past it.
    func limitDidChange() {
        idleTimer?.invalidate()
        lockIfIdle()
    }

    func lockAll() {
        idleTimer?.invalidate()
        idleTimer = nil
        for (spaceId, folderId) in context.browserState.unlockedFolders() {
            let command = BrowserCommand.setFolderUnlocked(spaceId: spaceId, folderId: folderId, isUnlocked: false)
            if let window = context.windows.activeWindow {
                _ = try? window.applyBrowserCommand(command)
                window.hideLockedFolder(folderId, spaceId: spaceId, automatic: true)
            } else {
                _ = try? context.browserState.mutate(command)
            }
        }
    }

    /// Locks once the user has been idle for the limit, else checks again when the limit would be reached.
    private func lockIfIdle() {
        idleTimer = nil
        // Folders locked by hand since leave nothing for the timer to guard.
        guard !context.browserState.unlockedFolders().isEmpty else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let limit = TimeInterval((context.settingsStore?.folderAutoLockMinutes ?? 15) * 60)
        guard idle < limit else { return lockAll() }
        let timer = Timer.scheduledTimer(withTimeInterval: limit - idle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfIdle() }
        }
        timer.tolerance = min((limit - idle) / 10, 30)
        idleTimer = timer
    }
}
