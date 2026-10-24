import XCTest
@testable import Lilo

@MainActor
final class PowerKeeperTests: XCTestCase {
    private final class FakeHelper: NSObject, PowerHelperProtocol {
        var calls: [String] = []
        var holdResult = true
        var otherClients = 0
        /// Set, `releaseAll` keeps its reply here instead of answering at once.
        var heldReleaseReply: ((Int) -> Void)?
        var holdsReleaseReply = false
        func holdAwake(reply: @escaping (Bool) -> Void) { calls.append("holdAwake"); reply(holdResult) }
        func releaseAll(reply: @escaping (Int) -> Void) {
            calls.append("releaseAll")
            if holdsReleaseReply { heldReleaseReply = reply } else { reply(otherClients) }
        }
        func setLowPowerMode(_ on: Bool, reply: @escaping (Bool) -> Void) { calls.append("lowPower \(on)"); reply(true) }
        func freeze(pids: [NSNumber], starts: [NSNumber], reply: @escaping ([NSNumber]) -> Void) { calls.append("freeze"); reply(pids) }
        func thaw(reply: @escaping () -> Void) { calls.append("thaw"); reply() }
    }

    private final class FakeLink: PowerHelperLink {
        let fake = FakeHelper()
        var helper: PowerHelperProtocol { fake }
        var onLost: ((Bool) -> Void)?
        var closed = false
        func close() { closed = true }
    }

    private final class FakeInstaller: PowerHelperInstaller {
        var status = "notRegistered"
        var statusAfterRegister = "enabled"
        var calls: [String] = []
        func register() { calls.append("register"); status = statusAfterRegister }
        func unregister() { calls.append("unregister"); status = "notRegistered" }
    }

    private final class FakeLidActions: LidActions {
        var calls: [String] = []
        func sampleBrightness() { calls.append("sample") }
        func lidClosed(helper: PowerHelperProtocol, settings: PowerKeeper.Settings) { calls.append("closed") }
        func lidOpened(helper: PowerHelperProtocol) { calls.append("opened") }
    }

    private var links: [FakeLink] = []
    private var holdResult = true
    private var otherClients = 0
    private var notifications: [(title: String, body: String)] = []
    private let installer = FakeInstaller()
    private let lidActions = FakeLidActions()

    private func makeKeeper(lidClosed: Bool = false, maxAwake: TimeInterval = 3600) -> PowerKeeper {
        let keeper = PowerKeeper(
            quietLimit: 0.2,
            makeLink: { [unowned self] in
                let link = FakeLink()
                link.fake.holdResult = holdResult
                link.fake.otherClients = otherClients
                links.append(link)
                return link
            },
            installer: installer,
            notify: { [unowned self] title, body in notifications.append((title, body)) }
        )
        keeper.start(lidActions: { [lidActions] in lidActions })
        keeper.apply(settings(lidClosed: lidClosed, maxAwake: maxAwake))
        return keeper
    }

    private func settings(lidClosed: Bool, maxAwake: TimeInterval = 3600) -> PowerKeeper.Settings {
        var settings = PowerKeeper.Settings(get: { _ in nil })
        settings.lidClosed = lidClosed
        settings.maxAwake = maxAwake
        return settings
    }

    private func status(busy: Bool = true, printing: Bool = true, awaiting: Bool = false) -> TerminalSession.Status {
        var status = TerminalSession.Status()
        status.state = busy ? .busy : .succeeded
        status.printing = printing
        status.awaitingInputSince = awaiting ? Date() : nil
        return status
    }

    func testAPrintingCommandKeepsTheMacAwakeUntilItEnds() {
        let keeper = makeKeeper()
        let id = UUID()
        keeper.terminalStatusChanged(id, status())
        XCTAssertEqual(keeper.state.working.count, 1)
        XCTAssertTrue(keeper.state.keepsAwake)

        keeper.terminalStatusChanged(id, status(busy: false))
        XCTAssertFalse(keeper.state.keepsAwake)
    }

    func testAWaitingCommandLetsTheMacSleep() {
        let keeper = makeKeeper(lidClosed: true)
        let id = UUID()
        keeper.terminalStatusChanged(id, status())
        XCTAssertTrue(keeper.state.holdsLidClosed)

        keeper.terminalStatusChanged(id, status(awaiting: true))

        XCTAssertFalse(keeper.state.keepsAwake)
        XCTAssertEqual(links[0].fake.calls.last, "releaseAll")
        XCTAssertTrue(links[0].closed, "closing the link gives sleep back")
    }

    func testAQuietCommandStopsCountingAfterTheQuietLimitUnlessKeptAwake() async throws {
        let keeper = makeKeeper()
        let server = UUID(), build = UUID()
        keeper.terminalStatusChanged(server, status(printing: false))
        keeper.terminalStatusChanged(build, status(printing: false))
        keeper.keepAwakeUntilDone(build)
        XCTAssertEqual(keeper.state.working.count, 2)

        await pollUntil(timeout: 5) { keeper.state.working.count == 1 }

        XCTAssertEqual(keeper.state.working.count, 1, "the silent server no longer counts, the kept build does")
    }

    func testABrowserAgentWorksForTheQuietLimitAfterItsLastCall() async throws {
        let keeper = makeKeeper()
        let agent = UUID()

        keeper.browserAgentWorked(agent)
        XCTAssertEqual(keeper.state.working, [agent])
        try await Task.sleep(for: .milliseconds(120))
        keeper.browserAgentWorked(agent)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(keeper.state.working, [agent], "each call restarts the quiet limit")

        let expired = await pollUntil { keeper.state.working.isEmpty }

        XCTAssertTrue(expired)
    }

    func testAQuietInteractivePromptStopsCountingAtOnceUnlessKeptAwake() {
        let keeper = makeKeeper()
        let agent = UUID()
        var prompt = status()
        prompt.bracketedPaste = true
        keeper.terminalStatusChanged(agent, prompt)
        XCTAssertEqual(keeper.state.working, [agent], "an agent printing its spinner works")

        prompt.printing = false
        keeper.terminalStatusChanged(agent, prompt)
        XCTAssertTrue(keeper.state.working.isEmpty, "an agent quiet at its prompt waits for the user")

        keeper.keepAwakeUntilDone(agent)
        XCTAssertEqual(keeper.state.working, [agent])
    }

    func testLidClosedModeHoldsTheHelperAndAppliesTheLidActions() {
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].fake.calls, ["holdAwake"])

        keeper.lidChanged(closed: true)
        XCTAssertEqual(lidActions.calls, ["sample", "closed"])
        XCTAssertEqual(links[0].fake.calls.last, "lowPower true")

        keeper.lidChanged(closed: false)
        XCTAssertEqual(lidActions.calls.suffix(2), ["opened", "sample"])
        XCTAssertEqual(links[0].fake.calls.last, "lowPower false")
        XCTAssertEqual(notifications.count, 1, "the summary of the closed period")
    }

    func testTheSummaryCountsOnlyCommandsThatEndedAndSaysHowLongOthersWait() {
        let keeper = makeKeeper(lidClosed: true)
        let done = UUID(), asking = UUID(), still = UUID()
        for id in [done, asking, still] { keeper.terminalStatusChanged(id, status()) }
        keeper.lidChanged(closed: true)

        keeper.terminalStatusChanged(done, status(busy: false))
        keeper.terminalStatusChanged(asking, status(awaiting: true))
        keeper.lidChanged(closed: false)

        let body = notifications.last?.body ?? ""
        XCTAssertTrue(body.hasPrefix(String(format: "%d commands finished".localized, 1)), body)
        XCTAssertTrue(body.contains(String(format: "%d wait for your answer, the oldest for %@".localized, 1, "")), body)
    }

    func testLowBatteryGivesSleepBackAndTheChargerTakesItAgain() {
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())

        keeper.powerChanged(onBattery: true, percent: 15)
        XCTAssertFalse(keeper.state.holdsLidClosed)
        XCTAssertTrue(links[0].closed)
        XCTAssertEqual(notifications.count, 1)

        keeper.powerChanged(onBattery: false, percent: 15)
        XCTAssertTrue(keeper.state.holdsLidClosed)
        XCTAssertEqual(links.count, 2)
    }

    func testHeatTurnsLowPowerModeOnThenGivesSleepBack() {
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())

        keeper.thermalChanged(.serious)
        XCTAssertEqual(links[0].fake.calls.last, "lowPower true")

        keeper.thermalChanged(.critical)
        XCTAssertFalse(keeper.state.holdsLidClosed)
    }

    func testTheMaximumDurationGivesSleepBackUntilEveryCommandStops() async throws {
        let keeper = makeKeeper(lidClosed: true, maxAwake: 0.2)
        let id = UUID()
        keeper.terminalStatusChanged(id, status())

        await pollUntil(timeout: 5) { !keeper.state.holdsLidClosed }
        XCTAssertFalse(keeper.state.holdsLidClosed)

        keeper.terminalStatusChanged(id, status(busy: false))
        keeper.terminalStatusChanged(id, status())
        XCTAssertTrue(keeper.state.holdsLidClosed)
    }

    func testChangingTheMaximumDurationWhileHeldReArmsIt() async throws {
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())

        keeper.apply(settings(lidClosed: true, maxAwake: 0.2))
        await pollUntil(timeout: 5) { !keeper.state.holdsLidClosed }

        XCTAssertFalse(keeper.state.holdsLidClosed)
    }

    func testSnoozeLastsUntilACommandStartsWorking() {
        let keeper = makeKeeper()
        let agent = UUID(), other = UUID()
        keeper.terminalStatusChanged(agent, status())
        keeper.snooze()
        XCTAssertFalse(keeper.state.keepsAwake)

        keeper.terminalStatusChanged(other, status())
        XCTAssertTrue(keeper.state.keepsAwake, "a new command ends the snooze")

        keeper.snooze()
        keeper.terminalStatusChanged(agent, status(busy: false))
        keeper.terminalStatusChanged(agent, status())
        XCTAssertTrue(keeper.state.keepsAwake, "so does the next command in the same terminal")
    }

    func testTurningTheLidModeOffUnregistersOnceTheHelperGaveEverythingBack() {
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())

        keeper.apply(settings(lidClosed: false))

        XCTAssertEqual(links[0].fake.calls.last, "releaseAll")
        XCTAssertTrue(links[0].closed)
        XCTAssertEqual(installer.calls, ["register", "unregister"])
    }

    func testTurningTheLidModeBackOnBeforeTheHelperAnswersKeepsItRegistered() {
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())
        links[0].fake.holdsReleaseReply = true

        keeper.apply(settings(lidClosed: false))
        keeper.apply(settings(lidClosed: true))
        links[0].fake.heldReleaseReply?(0)

        XCTAssertEqual(installer.calls, ["register"])
        XCTAssertEqual(keeper.state.helperStatus, "enabled")
    }

    func testTurningTheLidModeOffKeepsTheHelperWhileAnotherLiloUsesIt() {
        otherClients = 1
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())

        keeper.apply(settings(lidClosed: false))

        XCTAssertEqual(installer.calls, ["register"])
    }

    func testAHelperLostWithTheReplacedAppIsRegisteredAgain() {
        installer.status = "notFound"
        let keeper = makeKeeper(lidClosed: true)

        XCTAssertEqual(installer.calls, ["register"])
        XCTAssertEqual(keeper.state.helperStatus, "enabled")
    }

    func testAnUnapprovedHelperIsNeitherReachedNorReportedUntilApproved() {
        installer.statusAfterRegister = "requiresApproval"
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())
        XCTAssertTrue(links.isEmpty)
        XCTAssertFalse(keeper.state.holdsLidClosed)
        XCTAssertEqual(keeper.state.helperStatus, "requiresApproval")

        installer.status = "enabled"
        keeper.refreshHelperStatus()

        XCTAssertTrue(keeper.state.holdsLidClosed)
    }

    func testAFailedHoldIsNotReportedAndDoesNotDimTheLid() {
        holdResult = false
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())
        keeper.lidChanged(closed: true)

        XCTAssertFalse(keeper.state.holdsLidClosed)
        XCTAssertTrue(links[0].closed)
        XCTAssertFalse(lidActions.calls.contains("closed"))
    }

    func testAnInvalidatedHelperIsNotRetriedUntilItsStatusIsReadAgain() {
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())
        keeper.lidChanged(closed: true)

        links[0].onLost?(true)

        XCTAssertFalse(keeper.state.holdsLidClosed)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(lidActions.calls.last, "opened", "what Lilo changed itself is put back")

        keeper.refreshHelperStatus()
        XCTAssertEqual(links.count, 2)
    }

    func testALostHelperIsReachedAgain() {
        let keeper = makeKeeper(lidClosed: true)
        keeper.terminalStatusChanged(UUID(), status())

        links[0].onLost?(false)

        XCTAssertTrue(links[0].closed)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[1].fake.calls, ["holdAwake"])
    }

    func testAnUnchangedStateIsNotPublishedAgain() {
        let keeper = makeKeeper()
        var published = 0
        keeper.onChange = { _ in published += 1 }
        let id = UUID()
        keeper.terminalStatusChanged(id, status())
        keeper.terminalStatusChanged(id, status())
        XCTAssertEqual(published, 1)
    }
}
