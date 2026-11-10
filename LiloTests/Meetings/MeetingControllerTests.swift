import XCTest
@testable import Lilo

@MainActor
final class MeetingControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private lazy var horizon = now + 24 * 60 * 60

    private func meeting(_ id: String, startsIn minutes: Double) -> MeetingController.Meeting {
        .init(id: id, title: id, start: now + minutes * 60, url: nil)
    }

    func testAMeetingShowsTenMinutesBeforeItStarts() {
        let later = meeting("standup", startsIn: 25)
        let pick = MeetingController.pick([later], at: now, dismissed: [], until: horizon)
        XCTAssertNil(pick.shown)
        XCTAssertEqual(pick.next, later.start - 10 * 60)

        let soon = meeting("standup", startsIn: 4)
        let shown = MeetingController.pick([soon], at: now, dismissed: [], until: horizon)
        XCTAssertEqual(shown.shown, soon)
        XCTAssertEqual(shown.next, soon.start, "the start itself changes what the card says")
    }

    func testAStartedMeetingStaysFiveMinutesThenGivesWayToTheNextOne() {
        let started = meeting("review", startsIn: -2)
        let next = meeting("planning", startsIn: 30)
        let pick = MeetingController.pick([started, next], at: now, dismissed: [], until: horizon)
        XCTAssertEqual(pick.shown, started)
        XCTAssertEqual(pick.next, started.start + 5 * 60)

        let upcoming = meeting("sync", startsIn: 3)
        XCTAssertEqual(MeetingController.pick([started, upcoming], at: now, dismissed: [], until: horizon).shown, upcoming)
    }

    func testADismissedMeetingNeverShowsAndNothingAheadWaitsForTheHorizon() {
        let soon = meeting("standup", startsIn: 4)
        let pick = MeetingController.pick([soon], at: now, dismissed: ["standup"], until: horizon)
        XCTAssertNil(pick.shown)
        XCTAssertEqual(pick.next, horizon)
    }

    func testTheJoinLinkComesFromTheEventURLThenLocationThenNotes() {
        let event = URL(string: "https://example.com/event")
        let location = "Room 4, https://example.com/location"
        let notes = "Agenda at http://example.com/plain then join https://example.com/notes and https://example.com/help"
        XCTAssertEqual(MeetingController.joinLink(url: event, location: location, notes: notes), event)
        XCTAssertEqual(MeetingController.joinLink(url: nil, location: location, notes: notes)?.absoluteString, "https://example.com/location")
        XCTAssertEqual(MeetingController.joinLink(url: nil, location: "Room 4", notes: notes)?.absoluteString, "https://example.com/notes")
    }

    func testAnEventWithoutAnHTTPSLinkHasNoJoinLink() {
        XCTAssertNil(MeetingController.joinLink(url: URL(string: "http://example.com"), location: "Room 4", notes: "Bring slides, see http://example.com"))
        XCTAssertNil(MeetingController.joinLink(url: nil, location: nil, notes: nil))
    }
}
