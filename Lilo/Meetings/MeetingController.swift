import AppKit
import EventKit

/// The calendar event about to start, read from every calendar macOS Calendar holds through EventKit.
/// Off unless the setting enables it: while off it holds no event store, no observer and no timer.
@MainActor
final class MeetingController {
    static let enabledKey = "meetingCard"
    /// The card shows from `lead` before an event starts until `grace` after.
    static let lead: TimeInterval = 10 * 60
    static let grace: TimeInterval = 5 * 60
    /// How far ahead one read looks: past it, the timer only reads again.
    private static let horizon: TimeInterval = 24 * 60 * 60
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    struct Meeting: Equatable {
        /// One occurrence of an event: a recurring event shares its identifier across occurrences.
        let id: String
        let title: String
        let start: Date
        let url: URL?
    }

    private let settingsStore: SettingsStore
    private var store: EKEventStore?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var dismissedIds: Set<String> = []
    private(set) var current: Meeting?

    /// The shown meeting changed.
    var onChange: (() -> Void)?
    /// Calendar access was refused, so the setting was turned back off.
    var onDisabled: (() -> Void)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        // Never prompts: access is asked for only when the setting is turned on.
        if isEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess { start(EKEventStore()) }
    }

    var isEnabled: Bool { settingsStore.get(Self.enabledKey) == "true" }

    /// Follows the setting; the store already holds the new value.
    func enabledDidChange() {
        guard isEnabled else { return stop() }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            start(EKEventStore())
        case .notDetermined:
            let store = EKEventStore()
            Task { [weak self] in
                let granted = (try? await store.requestFullAccessToEvents()) ?? false
                guard let self, isEnabled else { return }
                if granted { start(store) } else { disable() }
            }
        default:
            // Refused before: macOS asks no more, only its settings can grant access.
            disable()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func dismiss(_ id: String) {
        dismissedIds.insert(id)
        refresh()
    }

    var bridgeState: [String: Any] {
        guard let current else { return ["meeting": NSNull()] }
        return ["meeting": [
            "id": current.id, "title": current.title, "start": current.start.timeIntervalSince1970 * 1000,
            "url": current.url?.absoluteString ?? NSNull()
        ] as [String: Any]]
    }

    /// The meeting shown at `now`, and when that next changes: an upcoming meeting wins over one already
    /// started, the soonest first. `meetings` are sorted by start.
    static func pick(_ meetings: [Meeting], at now: Date, dismissed: Set<String>, until horizon: Date) -> (shown: Meeting?, next: Date) {
        var upcoming: Meeting?
        var started: Meeting?
        var next = horizon
        for meeting in meetings where !dismissed.contains(meeting.id) {
            let showFrom = meeting.start - lead
            let showUntil = meeting.start + grace
            if showFrom > now {
                next = min(next, showFrom)
            } else if showUntil > now {
                next = min(next, meeting.start > now ? meeting.start : showUntil)
                if meeting.start > now { upcoming = upcoming ?? meeting } else { started = meeting }
            }
        }
        return (upcoming ?? started, next)
    }

    /// The link that joins an event, from the event alone: its URL, else the first https link in its
    /// location, else in its notes.
    static func joinLink(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, url.scheme?.lowercased() == "https" { return url }
        for text in [location, notes] {
            guard let text, !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let link = linkDetector?.matches(in: text, range: range).lazy
                .compactMap(\.url).first { $0.scheme?.lowercased() == "https" }
            if let link { return link }
        }
        return nil
    }

    private func start(_ store: EKEventStore) {
        guard self.store == nil else { return refresh() }
        self.store = store
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (.default, NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main, using: refresh)),
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh))
        ]
        self.refresh()
    }

    private func stop() {
        observers.forEach { center, observer in center.removeObserver(observer) }
        observers = []
        timer?.invalidate()
        timer = nil
        store = nil
        dismissedIds = []
        show(nil)
    }

    private func disable() {
        settingsStore.set(Self.enabledKey, value: "false")
        stop()
        onDisabled?()
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        guard let store else { return }
        let now = Date()
        let horizon = now + Self.horizon
        let meetings = store.events(matching: store.predicateForEvents(withStart: now - Self.grace, end: horizon, calendars: nil))
            .filter { event in
                !event.isAllDay && event.status != .canceled
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .map { event in
                Meeting(
                    id: "\(event.calendarItemIdentifier)@\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "",
                    start: event.startDate,
                    url: Self.joinLink(url: event.url, location: event.location, notes: event.notes)
                )
            }
            .sorted { $0.start < $1.start }
        dismissedIds.formIntersection(meetings.map(\.id))
        let (shown, next) = Self.pick(meetings, at: now, dismissed: dismissedIds, until: horizon)
        show(shown)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func show(_ meeting: Meeting?) {
        guard meeting != current else { return }
        current = meeting
        onChange?()
    }
}
