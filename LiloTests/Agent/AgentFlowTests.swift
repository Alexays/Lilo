import XCTest
@testable import Lilo

@MainActor
final class AgentFlowTests: AgentToolTestCase {
    private static let page = """
    <!doctype html><title>Contact details</title><body>
    <h1>Contact details</h1>
    <label>Phone <input id="phone" inputmode="tel" autocomplete="off"></label>
    <label>Password <input id="secret" type="password"></label>
    <button id="save">Save</button><p id="result" role="status"></p>
    <script>
    document.getElementById('save').onclick = () => {
      window.saved = (window.saved ?? 0) + 1
      document.getElementById('result').textContent = 'Saved'
    }
    </script>
    </body>
    """

    private func ref(_ text: String, in output: String) throws -> String {
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.contains(text) && $0.contains("ref_") }, "\(text) not in \(output)")
        let range = try XCTUnwrap(line.range(of: #"(f[a-z0-9]+_)?ref_\d+"#, options: .regularExpression))
        return String(line[range])
    }

    /// Reads the page, then records `body` between flow_start and flow_save("name"), returning the save reply.
    private func recordFlow(
        _ name: String, tab: Int, params: [String: Any]? = nil,
        body: (String) async throws -> Void
    ) async throws -> (save: String, phoneRef: String) {
        let read = await client.callTool("read_page", ["tabId": tab, "filter": "interactive"])
        let phoneRef = try ref("Phone", in: read.text)
        var startArgs: [String: Any] = ["tabId": tab]
        startArgs["name"] = name
        let start = await client.callTool("flow_start", startArgs)
        XCTAssertFalse(start.isError, start.text)
        try await body(phoneRef)
        var saveArgs: [String: Any] = ["name": name]
        saveArgs["params"] = params
        let save = await client.callTool("flow_save", saveArgs)
        XCTAssertFalse(save.isError, save.text)
        return (save.text, phoneRef)
    }

    /// flow_run's JSON reply.
    private func runResult(_ reply: (text: String, isError: Bool, images: [Data], meta: [String: Any])) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any], reply.text)
    }

    func testRecordSaveAndReplayFillsTheParam() async throws {
        let tab = try await agentTab(showing: Self.page)
        let (save, _) = try await recordFlow("set-phone", tab: tab) { phoneRef in
            let fill = await client.callTool("form_input", ["tabId": tab, "ref": phoneRef, "value": "555 010 0199", "flowParam": "phone"])
            XCTAssertFalse(fill.isError, fill.text)
            let saveRef = try self.ref("Save", in: (await client.callTool("read_page", ["tabId": tab, "filter": "interactive"])).text)
            let click = await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": saveRef])
            XCTAssertFalse(click.isError, click.text)
        }
        XCTAssertTrue(save.contains("Saved flow \"set-phone\""), save)
        XCTAssertTrue(save.contains("parameters: phone"), save)

        try await js("document.getElementById('phone').value=''; window.saved=0; document.getElementById('result').textContent=''", tab: tab)
        let run = await client.callTool("flow_run", ["name": "set-phone", "tabId": tab, "params": ["phone": "555 010 0199"]])

        XCTAssertFalse(run.isError, run.text)
        let result = try runResult(run)
        XCTAssertEqual(result["completed"] as? Int, 2, run.text)
        XCTAssertEqual(try await js("document.getElementById('phone').value", tab: tab) as? String, "555 010 0199")
        XCTAssertEqual(try await js("window.saved", tab: tab) as? Int, 1, "a replay saves exactly once")
    }

    func testAPasswordFieldRecordsAParameterNeverTheValue() async throws {
        let tab = try await agentTab(showing: Self.page)
        let (save, _) = try await recordFlow("sign-in", tab: tab) { _ in
            let read = await client.callTool("read_page", ["tabId": tab, "filter": "interactive"])
            let secretRef = try self.ref("Password", in: read.text)
            let fill = await client.callTool("form_input", ["tabId": tab, "ref": secretRef, "value": "hunter2-example"])
            XCTAssertFalse(fill.isError, fill.text)
        }
        XCTAssertTrue(save.contains("parameters:"), save)
        let file = AgentFlows.directory(control: control).appending(path: "sign-in.jsonl")
        let contents = String(decoding: FileManager.default.contents(atPath: file.path)!, as: UTF8.self)
        XCTAssertFalse(contents.contains("hunter2-example"), "the secret never reaches the file")
        XCTAssertTrue(contents.contains(#""param""#), contents)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let run = await client.callTool("flow_run", ["name": "sign-in", "tabId": tab])
        XCTAssertTrue(run.isError)
        XCTAssertTrue(run.text.contains("needs parameters"), run.text)

        let filled = await client.callTool("flow_run", ["name": "sign-in", "tabId": tab, "params": ["password": "open-sesame-9"]])
        XCTAssertFalse(filled.isError, filled.text)
        XCTAssertEqual(try await js("document.getElementById('secret').value", tab: tab) as? String, "open-sesame-9")
    }

    func testALocatorMissStopsTheRunAtThatStep() async throws {
        let tab = try await agentTab(showing: Self.page)
        _ = try await recordFlow("set-phone", tab: tab) { phoneRef in
            let saveRef = try self.ref("Save", in: (await client.callTool("read_page", ["tabId": tab, "filter": "interactive"])).text)
            _ = await client.callTool("form_input", ["tabId": tab, "ref": phoneRef, "value": "1", "flowParam": "phone"])
            _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": saveRef])
        }
        // The page drifts: the button's name is no longer the recorded one. Replay must stop, not guess.
        try await js("document.getElementById('save').textContent='Delete'", tab: tab)

        let run = await client.callTool("flow_run", ["name": "set-phone", "tabId": tab, "params": ["phone": "2"]])

        let result = try runResult(run)
        XCTAssertEqual(result["failedStep"] as? Int, 2, run.text)
        XCTAssertEqual(result["completed"] as? Int, 1, run.text)
        XCTAssertTrue((result["reason"] as? String ?? "").contains("no longer matches"), run.text)
    }

    func testARefusedConsentStopsTheRunLikeALiveCall() async throws {
        let page = """
        <!doctype html><body><button id="pay">Pay now</button>
        <script>document.getElementById('pay').onclick = () => window.paid = true</script></body>
        """
        let tab = try await agentTab(showing: page)
        _ = try await recordFlow("checkout", tab: tab) { _ in
            let read = await client.callTool("read_page", ["tabId": tab, "filter": "interactive"])
            let payRef = try self.ref("Pay", in: read.text)
            let recording = Task { await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": payRef]) }
            await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
            control.answerConsent(control.pendingConsentAnswers.keys.first!, granted: true)
            _ = await recording.value
        }
        try await js("window.paid = false", tab: tab)

        let running = Task { await client.callTool("flow_run", ["name": "checkout", "tabId": tab]) }
        await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        control.answerConsent(control.pendingConsentAnswers.keys.first!, granted: false)
        let run = await running.value

        let result = try runResult(run)
        XCTAssertEqual(result["failedStep"] as? Int, 1, run.text)
        XCTAssertEqual(result["consent"] as? String, "denied", run.text)
        XCTAssertEqual(try await js("window.paid", tab: tab) as? Bool, false, "a refused click does not land")
    }

    func testAFlowEditedOnDiskFailsItsCheck() async throws {
        let tab = try await agentTab(showing: Self.page)
        _ = try await recordFlow("set-phone", tab: tab) { phoneRef in
            _ = await client.callTool("form_input", ["tabId": tab, "ref": phoneRef, "value": "1", "flowParam": "phone"])
        }
        let file = AgentFlows.directory(control: control).appending(path: "set-phone.jsonl")
        var contents = String(decoding: FileManager.default.contents(atPath: file.path)!, as: UTF8.self)
        contents = contents.replacingOccurrences(of: "textbox", with: "button")
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let run = await client.callTool("flow_run", ["name": "set-phone", "tabId": tab, "params": ["phone": "2"]])

        XCTAssertTrue(run.isError)
        XCTAssertTrue(run.text.contains("changed on disk"), run.text)
    }
}
