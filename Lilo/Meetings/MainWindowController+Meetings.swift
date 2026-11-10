import AppKit

extension MainWindowController {
    func sendMeeting() {
        bridgeRouter.send(event: "meetingChanged", data: context.meetings?.bridgeState ?? ["meeting": NSNull()])
    }

    /// Opens the meeting's link, on the Space's tab already showing it if there is one, and hides its card.
    func joinMeeting(_ id: String) {
        guard let meetings = context.meetings, let meeting = meetings.current, meeting.id == id else { return }
        if let url = meeting.url {
            if let tab = tabManager.currentTabs.first(where: { $0.url == url }) {
                activateTabStateFirst(id: tab.id)
            } else {
                createTabStateFirst(url: url)
            }
        }
        meetings.dismiss(id)
    }
}
