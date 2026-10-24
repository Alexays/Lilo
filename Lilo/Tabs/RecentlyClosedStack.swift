import Foundation

/// Maintains a stack of recently closed tabs for undo-close (Cmd+Shift+T).
/// Limited to 20 entries. Closed terminals are also saved across launches (BrowserContext).
struct RecentlyClosedStack {
    struct Entry: Sendable, Codable, Equatable {
        enum Content: Sendable, Codable, Equatable {
            case page(URL)
            case terminal(ClosedTerminal)
        }

        /// A terminal's shell dies with its tab: reopening it starts a new one in the same folder,
        /// below the screen it showed, with its last program typed at the prompt.
        struct ClosedTerminal: Sendable, Codable, Equatable {
            var cwd: String
            var title = ""
            var resumeCommand: String?
            var gitBranch = ""
            var closedAt = Date()
            /// The closed tab's id, which names its saved screen; nil when no screen was kept.
            var screenId: UUID?
        }

        let content: Content
        let spaceId: UUID
        let parentFolderId: UUID?
        let section: TabTreeItem.Section?
        let sortOrder: Int?
    }

    private var entries: [Entry] = []
    private let maxSize = 20

    mutating func push(
        _ content: Entry.Content,
        spaceId: UUID,
        parentFolderId: UUID?,
        section: TabTreeItem.Section?,
        sortOrder: Int?
    ) {
        let entry = Entry(
            content: content,
            spaceId: spaceId,
            parentFolderId: parentFolderId,
            section: section,
            sortOrder: sortOrder
        )
        entries.append(entry)
        if entries.count > maxSize {
            entries.removeFirst()
        }
    }

    mutating func pop() -> Entry? {
        entries.popLast()
    }

    /// Removes the `index`-th newest entry among those passing `isIncluded`.
    mutating func pop(at index: Int, where isIncluded: (Entry) -> Bool) -> Entry? {
        var remaining = index
        for position in entries.indices.reversed() where isIncluded(entries[position]) {
            if remaining == 0 { return entries.remove(at: position) }
            remaining -= 1
        }
        return nil
    }

    /// Puts entries from an earlier launch under this launch's, keeping the newest when full.
    mutating func restoreOlder(_ older: [Entry]) {
        entries = Array((older + entries).suffix(maxSize))
    }

    mutating func removeAll(inSpace spaceId: UUID) {
        entries.removeAll { $0.spaceId == spaceId }
    }

    /// Entries newest-first, for read-only surfaces such as chrome.sessions.getRecentlyClosed.
    var recentEntries: [Entry] {
        entries.reversed()
    }
}
