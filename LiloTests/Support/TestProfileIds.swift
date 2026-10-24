import Foundation
import WebKit

/// Profile ids for tests. WebKit serves only about 188 persistent data stores per app launch and the
/// suite builds several hundred profiles, so ids come from a small pool, wiped once their test ends.
@MainActor
enum TestProfileIds {
    /// Random per run: concurrent test runs must never share a store.
    private static var free = (0..<64).map { _ in UUID() }
    /// Handed out during the running test; none goes back to the pool before it ends.
    private static var taken: [UUID] = []

    /// A pooled id no other profile of the running test holds, or a fresh one once the pool runs dry.
    static func next() -> UUID {
        guard !free.isEmpty else { return UUID() }
        let id = free.removeFirst()
        taken.append(id)
        return id
    }

    /// Wipes what the ended test left under its ids (website data and chrome.storage) and returns each
    /// to the pool once wiped, so a test never sees another's data. The next test starts meanwhile.
    static func recycle() {
        guard !taken.isEmpty else { return }
        let extensionStorage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/\(Bundle.main.bundleIdentifier ?? "fr.arouillard.lilo")/WebExtensions")
        for id in taken {
            try? FileManager.default.removeItem(at: extensionStorage.appendingPathComponent(id.uuidString))
            WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.testDataTypes, modifiedSince: .distantPast) {
                MainActor.assumeIsolated { free.append(id) }
            }
        }
        taken = []
    }
}

extension WKWebsiteDataStore {
    /// Every type but Screen Time's, which the test host never reports to: each query of it waits on the
    /// system's Screen Time service, seconds when several test runs ask at once.
    static let testDataTypes = allWebsiteDataTypes().subtracting([WKWebsiteDataTypeScreenTime])
}
