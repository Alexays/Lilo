import Foundation

/// Maintains a stack of recently closed tabs for undo-close (Cmd+Shift+T).
/// Limited to 20 entries. Closed terminals are also saved across launches (BrowserContext).
struct RecentlyClosedStack {
    struct Entry: Sendable, Codable, Equatable {
        enum Content: Sendable, Codable, Equatable {
            case page(URL)
            case terminal(ClosedTerminal)
            /// A pinned or bookmarked tab removed from the sidebar, which comes back as it was.
            case savedTab(StoredTab)
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
        /// Unique for this launch and kept while the entry stays, so chrome.sessions ids name it; the stack assigns it.
        var id = 0
        var closedAt = Date()
        /// A page's back/forward list, scroll and form state (WebKit's `interactionState`), held in memory only.
        var interactionState: Data?

        // The id belongs to the launch: a saved entry gets a new one when restored.
        private enum CodingKeys: String, CodingKey { case content, spaceId, parentFolderId, section, sortOrder }
    }

    private var entries: [Entry] = []
    private let maxSize = 20
    private var nextId = 1

    mutating func push(
        _ content: Entry.Content,
        spaceId: UUID,
        parentFolderId: UUID?,
        section: TabTreeItem.Section?,
        sortOrder: Int?,
        interactionState: Data? = nil
    ) {
        let entry = Entry(
            content: content,
            spaceId: spaceId,
            parentFolderId: parentFolderId,
            section: section,
            sortOrder: sortOrder,
            id: nextId,
            interactionState: interactionState
        )
        nextId += 1
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
        let restored = older.map { entry in
            var entry = entry
            entry.id = nextId
            nextId += 1
            return entry
        }
        entries = Array((restored + entries).suffix(maxSize))
    }

    mutating func removeAll(inSpace spaceId: UUID) {
        entries.removeAll { $0.spaceId == spaceId }
    }

    /// Clearing history forgets the pages closed in its range (all of them without `cutoff`) of the spaces passing `isCleared`.
    mutating func removePages(closedSince cutoff: Date?, inSpaces isCleared: (UUID) -> Bool) {
        entries.removeAll { entry in
            guard case .page = entry.content else { return false }
            return entry.closedAt >= (cutoff ?? .distantPast) && isCleared(entry.spaceId)
        }
    }

    /// Entries newest-first, for read-only surfaces such as chrome.sessions.getRecentlyClosed.
    var recentEntries: [Entry] {
        entries.reversed()
    }
}
