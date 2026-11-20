import CryptoKit
import Foundation
import WebKit

/// Saved flows: an agent records a run of its own tool calls with `flow_start`, saves it with `flow_save` and
/// replays it with `flow_run`. A flow is JSONL: a header line, then one step per line whose `target` is a stable
/// locator ({role, name, nth}) read_page would give, never a ref or a pixel. Replay resolves each locator in the
/// live page and dispatches the step through `AgentTools.call`, so the consent gate, the action log and the
/// action delta behave exactly as for a live call. A locator that resolves nothing stops the run: replay never
/// picks a near match, the agent takes the page back from there.
@MainActor
enum AgentFlows {

    /// What a session records between `flow_start` and `flow_save`: the steps, the symbolic id each tab number
    /// took (`@tab` first, `@tab2`...), and the mutating calls nothing stable could be stored for.
    struct Recording {
        var steps: [[String: Any]] = []
        var tabs: [Int: String] = [:]
        var dropped: [String] = []

        mutating func symbolicTab(_ number: Int?) -> String? {
            guard let number else { return nil }
            if let known = tabs[number] { return known }
            let name = tabs.isEmpty ? "@tab" : "@tab\(tabs.count + 1)"
            tabs[number] = name
            return name
        }
    }

    static let definitions: [[String: Any]] = [
        AgentTools.tool("flow_start", """
            Start recording a flow: the mutating tool calls you make from now on are kept as steps (stable \
            locators, never refs or coordinates), until flow_save writes them under a name or this connection \
            ends. Record to repeat the same task later: call flow_start, do the task once, then flow_save. \
            Reads (read_page, find, get_page_text, screenshots, console/network reads) and calls a locator \
            cannot express (javascript_tool, coordinate clicks, uploads) are not recorded. A value the user \
            must supply at each run, like a phone number or a password, is a parameter: pass "flowParam" with \
            its name on the call that types it, or declare it at flow_save. For a password, card or one-time \
            code field the value always becomes a parameter, never stored.
            """, [
                "tabId": AgentTools.prop("number", "The tab the recording starts on, for your notes; recording covers every tab you act on."),
                "name": AgentTools.prop("string", "The name flow_save will use if you do not give one.")
            ]),
        AgentTools.tool("flow_save", """
            Stop recording and save the flow under `name` (in Lilo's app support folder, as JSONL only you can \
            read). `params` maps each parameter name to the 1-based steps whose value it fills at run time, \
            for values recorded as literals. The reply lists the steps that still hold a literal value so you \
            can name any parameter you missed. A flow is a recording, not an authorization: its steps ask the \
            user exactly as your own calls would.
            """, [
                "name": AgentTools.prop("string", "Letters, digits and dashes."),
                "params": ["type": "object", "description": "Each parameter name to the step number (or numbers) whose value it becomes, e.g. {\"phone\": 3}."]
            ], required: ["name"]),
        AgentTools.tool("flow_run", """
            Replay a saved flow in `tabId`: each step's locator is resolved in the live page and run as the \
            tool call it records, asking the user where your own call would. Supply every parameter the flow \
            declares in `params`; a missing one fails before the first step. Returns how many steps ran and \
            which was the last that may have committed something. A step whose locator matches nothing, or \
            whose answer the user refuses or leaves, stops the run: the reply says which step and why, and \
            you then own the page again - read it, do that step yourself, and continue with `from` set to \
            the next step.
            """, [
                "name": AgentTools.prop("string", "The saved flow's name."),
                "tabId": AgentTools.prop("number", "The tab to replay in."),
                "params": ["type": "object", "description": "Every parameter the flow declares, by name."],
                "from": AgentTools.prop("number", "The 1-based step to resume at, 1 by default.")
            ], required: ["name", "tabId"])
    ]

    /// The short skill ACP conversations get as a prompt attachment: the tools do the work, this tells the agent
    /// they exist and how a parameter is marked.
    static let skill = """
        # Lilo saved flows
        To repeat a browser task later: call `flow_start`, do the task once, then `flow_save` with a name. \
        To redo it: `flow_run` with the name, the tab and every parameter. Mark a value the user must supply \
        each run (a password, a one-time code) by passing `flowParam` with its name on the call that types it; \
        `flow_save` lists the steps still holding literal values so you can declare them as parameters. A run \
        stops at the first step whose locator no longer matches and reports it: do that step yourself, then \
        call `flow_run` again with `from` set to the next step.
        """

    static func call(
        _ name: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async throws -> [AgentContent]? {
        switch name {
        case "flow_start":
            var recording = Recording()
            if let tab = (arguments["tabId"] as? NSNumber)?.intValue { _ = recording.symbolicTab(tab) }
            session.flow = recording
            session.flowName = (arguments["name"] as? String).flatMap { sanitized($0) }
            return [.text("Recording a flow. Do the task, then call flow_save to keep it under a name; every call a locator cannot express is left out.")]
        case "flow_save":
            return try await save(arguments, session: session, control: control)
        case "flow_run":
            return try await run(arguments, session: session, control: control)
        default:
            return nil
        }
    }

    // MARK: - Recording

    /// The tools whose calls become steps. `wait_for` is kept verbatim: it is already the synchronization
    /// mechanism, so replay invents no sleeps. Everything else - reads, devtools, uploads, scripts - is
    /// dropped; a mutating call a locator cannot express leaves a `dropped` note so the run can say why.
    static let recordable: Set<String> = ["navigate", "wait_for", "form_input", "computer", "fetch"]
    private static let clickActions: Set<String> = ["left_click", "right_click", "double_click", "triple_click", "hover", "scroll_to"]

    /// Appends the call that just succeeded to the session's recording, with refs traded for the locators
    /// `locate` reads off the live element and secrets traded for parameters. Called from AgentMCP after a
    /// successful call, so a step records exactly what ran.
    static func record(
        _ name: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async {
        guard var recording = session.flow, recordable.contains(name) else { return }
        defer { session.flow = recording }
        var step: [String: Any] = ["tool": name]
        var args: [String: Any] = [:]
        if let tab = recording.symbolicTab((arguments["tabId"] as? NSNumber)?.intValue) { args["tabId"] = tab }
        let drop = { (why: String) in
            recording.dropped.append("\(name): \(why)")
            step = ["dropped": "\(name): \(why)"]
        }
        switch name {
        case "navigate":
            guard let url = arguments["url"] as? String else { return }
            args["url"] = url
        case "wait_for":
            for key in ["text", "selector", "role", "name", "url", "state", "timeout"] { args[key] = arguments[key] ?? NSNull() }
            args = args.filter { !($0.value is NSNull) }
        case "form_input":
            guard let ref = arguments["ref"] as? String,
                  let located = try? await locate(ref, arguments: arguments, session: session, control: control) else {
                drop("the input's ref could not be read as a locator")
                break
            }
            args["target"] = located.target
            if let param = arguments["flowParam"] as? String {
                args["value"] = ["param": param]
            } else if located.sensitive {
                args["value"] = ["param": located.paramName]
            } else {
                args["value"] = arguments["value"]
            }
        case "computer":
            let action = arguments["action"] as? String ?? ""
            if clickActions.contains(action) {
                guard let ref = arguments["ref"] as? String,
                      let located = try? await locate(ref, arguments: arguments, session: session, control: control) else {
                    drop("\(action) without a ref cannot be replayed: coordinates record a pixel, not an intent")
                    break
                }
                args["action"] = action
                args["target"] = located.target
                if let modifiers = arguments["modifiers"] { args["modifiers"] = modifiers }
            } else if ["type", "insert_text", "key"].contains(action) {
                args["action"] = action
                if let param = arguments["flowParam"] as? String {
                    args["text"] = ["param": param]
                } else {
                    args["text"] = arguments["text"]
                }
                if let count = arguments["repeat"] { args["repeat"] = count }
            } else if action == "scroll" {
                args["action"] = action
                args["scroll_direction"] = arguments["scroll_direction"]
                args["scroll_amount"] = arguments["scroll_amount"]
            }
            // wait, screenshot and the rest record nothing: a replay needs no sleeps and no reads.
            else { return }
        case "fetch":
            args["url"] = arguments["url"]
            for key in ["method", "credentials", "responseType", "maxBytes"] { args[key] = arguments[key] ?? NSNull() }
            args = args.filter { !($0.value is NSNull) }
            // Bodies, headers and params are the action log's masked keys: never stored. A method that can
            // change the site replays flagged like the call it records.
            if !["GET", "HEAD"].contains((arguments["method"] as? String ?? "GET").uppercased()) { step["possibleCommit"] = true }
        default:
            return
        }
        step["args"] = args
        recording.steps.append(step)
    }

    /// The element `ref` points at, as a recorded locator: role and name as read_page gives them, its ordinal
    /// among the shown elements sharing both, and whether its value is a secret (password, card, one-time code),
    /// which `AgentPage.js` answers for the element's own frame. A frame's element is left out: its frame prefix
    /// is per-document, so no locator can name it across loads.
    private static func locate(
        _ ref: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async throws -> (target: [String: Any], sensitive: Bool, paramName: String) {
        let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
        if try await AgentTools.frame(holding: ref, in: engine) != nil {
            throw AgentToolError("frame element")
        }
        let answer = try await AgentTools.page(engine, "locate", ["ref": ref]) as? [String: Any] ?? [:]
        var target: [String: Any] = ["role": answer["role"] ?? "generic", "name": answer["name"] ?? ""]
        if let nth = (answer["nth"] as? NSNumber)?.intValue, nth > 0 { target["nth"] = nth }
        let sensitive = answer["sensitive"] as? Bool ?? false
        // The parameter a secret becomes: the field's name when the page gives one, else "secret".
        let label = (answer["name"] as? String ?? "secret").lowercased().unicodeScalars
            .map { $0.properties.isAlphabetic || ("0"..."9").contains($0) ? Character($0) : "-" }
        let paramName = String(String(label).split(separator: "-").joined(separator: "-").prefix(30))
        return (target, sensitive, paramName.isEmpty ? "secret" : paramName)
    }

    // MARK: - Store

    static func directory(control: AgentControl) -> URL {
        URL(fileURLWithPath: control.context?.appSupportDirectory ?? BuildIdentity.appSupportDirectory).appending(path: "Agents/Flows")
    }

    static func sanitized(_ name: String) -> String? {
        let kept = name.lowercased().unicodeScalars.map { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") ? Character($0) : "-" }
        let result = String(String(kept).split(separator: "-").joined(separator: "-").prefix(60))
        return result.isEmpty ? nil : result
    }

    private static func file(_ name: String, control: AgentControl) -> URL? {
        sanitized(name).map { directory(control: control).appending(path: $0 + ".jsonl") }
    }

    /// The canonical encoding of the steps the hash covers: one sorted-keys JSON object per line.
    private static func stepLines(_ steps: [[String: Any]]) throws -> [String] {
        try steps.map {
            let data = try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func hash(_ lines: [String]) -> String {
        SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { unsafe String(format: "%02x", $0) }.joined()
    }

    /// Writes the recording as `<name>.jsonl` (header, then a step per line, mode 0600): the header holds the
    /// param names and the steps' hash, so a flow edited on disk fails its check instead of replaying unseen
    /// steps the user once saw.
    private static func save(_ arguments: [String: Any], session: AgentSession, control: AgentControl) async throws -> [AgentContent] {
        guard let recording = session.flow else { throw AgentToolError("Nothing is recording: call flow_start first") }
        session.flow = nil
        guard let name = sanitized(arguments["name"] as? String ?? session.flowName ?? ""),
              let file = file(name, control: control) else { throw AgentToolError("Give the flow a name of letters, digits and dashes") }
        var steps = recording.steps
        // Params declared at save turn those steps' literal value/text into {"param": name}.
        var paramNames = Set<String>()
        if let declared = arguments["params"] as? [String: Any] {
            for (param, which) in declared {
                paramNames.insert(param)
                let indexes = ([which] + (which as? [Any] ?? [])).compactMap { ($0 as? NSNumber)?.intValue }
                for index in indexes where steps.indices.contains(index - 1) {
                    guard var args = steps[index - 1]["args"] as? [String: Any] else { continue }
                    for key in ["value", "text"] where !(args[key] is [String: Any]) && args[key] != nil {
                        args[key] = ["param": param]
                    }
                    steps[index - 1]["args"] = args
                }
            }
        }
        paramNames.formUnion(stepParams(steps))
        let site = steps.lazy.compactMap { ($0["args"] as? [String: Any])?["url"] as? String }
            .compactMap { URL(string: $0)?.host }.first
        let lines = try stepLines(steps)
        let header: [String: Any] = [
            "flow": name, "site": site ?? "", "params": paramNames.sorted(), "steps": steps.count,
            "recordedAt": Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false)),
            "sha256": hash(lines)
        ]
        var data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        for line in lines { data.append(contentsOf: line.utf8); data.append(0x0A) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory(control: control), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var reply = "Saved flow \"\(name)\" with \(steps.count) steps" + (site.map { " on \($0)" } ?? "")
            + (paramNames.isEmpty ? "" : "; parameters: \(paramNames.sorted().joined(separator: ", "))")
        let literals = steps.indices.filter { index in
            guard let args = steps[index]["args"] as? [String: Any] else { return false }
            return ["value", "text"].contains { args[$0] is String || args[$0] is NSNumber || args[$0] is Bool }
        }
        if !literals.isEmpty {
            reply += "\nSteps holding a literal value (declare them as params if the user should supply them each run): "
                + literals.map { "\($0 + 1) (\(steps[$0]["tool"] ?? "?"))" }.joined(separator: ", ")
        }
        if !recording.dropped.isEmpty {
            reply += "\nNot recorded, replay stops at these steps: " + recording.dropped.joined(separator: "; ")
        }
        return [.text(reply)]
    }

    /// Every `{"param": key}` anywhere in the steps' arguments.
    private static func stepParams(_ steps: [[String: Any]]) -> Set<String> {
        var names = Set<String>()
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let param = object["param"] as? String, object.count == 1 { names.insert(param); return }
                object.values.forEach(walk)
            } else if let array = value as? [Any] { array.forEach(walk) }
        }
        for step in steps { walk(step["args"] ?? [:]) }
        return names
    }

    // MARK: - Replay

    /// Runs the steps back through `AgentTools.call`, so a replayed click asks consent, logs and reports its
    /// delta exactly like a live one. Stops at the first step that fails and reports which and why.
    private static func run(_ arguments: [String: Any], session: AgentSession, control: AgentControl) async throws -> [AgentContent] {
        guard let file = file(arguments["name"] as? String ?? "", control: control),
              let data = FileManager.default.contents(atPath: file.path) else {
            throw AgentToolError("No flow named \"\(arguments["name"] as? String ?? "")\"")
        }
        let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        guard let headerLine = lines.first,
              let header = try? JSONSerialization.jsonObject(with: Data(headerLine.utf8)) as? [String: Any] else {
            throw AgentToolError("Flow \"\(arguments["name"] ?? "")\" is not a saved flow")
        }
        let stepLines = Array(lines.dropFirst())
        guard hash(stepLines) == header["sha256"] as? String else {
            throw AgentToolError("Flow \"\(header["flow"] ?? "")\" changed on disk since it was saved: save it again rather than editing the file")
        }
        let steps = stepLines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        // Every parameter must be supplied before the first step runs.
        let params = arguments["params"] as? [String: Any] ?? [:]
        let missing = stepParams(steps).subtracting(params.keys)
        guard missing.isEmpty else {
            throw AgentToolError("Flow \"\(header["flow"] ?? "")\" needs parameters: \(missing.sorted().joined(separator: ", "))")
        }
        let tabId = arguments["tabId"]
        guard (tabId as? NSNumber) != nil else { throw AgentToolError("flow_run needs the tab to replay in") }
        let from = max((arguments["from"] as? NSNumber)?.intValue ?? 1, 1)
        var completed = min(from - 1, steps.count)
        var lastPossibleCommit = steps[..<completed].lastIndex { $0["possibleCommit"] as? Bool == true }.map { $0 + 1 }
        for index in completed..<steps.count {
            let step = steps[index]
            if let why = step["dropped"] as? String {
                return [.text(runResult(header, completed: completed, failedStep: index + 1,
                                        reason: "This step was never recorded as a locator (\(why)): do it yourself, then call flow_run with from: \(index + 2)"))]
            }
            var args = (step["args"] as? [String: Any] ?? [:]).mapValues { substitute($0, params: params) }
            guard let tool = step["tool"] as? String else { continue }
            args["tabId"] = args["tabId"] as? String == "@tab" ? tabId : args["tabId"]
            if let tabArg = args["tabId"] as? String, tabArg.hasPrefix("@") {
                return [.text(runResult(header, completed: completed, failedStep: index + 1,
                                        reason: "The flow acts on a second tab \(tabArg): replay supports one tab"))]
            }
            // The step's locator becomes the ref the tool knows; a miss or a renamed element stops the run.
            if let target = args["target"] as? [String: Any] {
                let (_, engine) = try control.agentTab(tabId, session: session)
                guard let resolved = try? await AgentTools.page(engine, "resolveTarget", target) as? [String: Any],
                      let ref = resolved["ref"] as? String else {
                    return [.text(runResult(header, completed: completed, failedStep: index + 1,
                                            reason: "No element matches \(AgentTools.json(target)): the page no longer matches the recording"))]
                }
                args.removeValue(forKey: "target")
                args["ref"] = ref
            }
            args.removeValue(forKey: "flowParam")
            let sent = AgentCallSent()
            do {
                _ = try await AgentCallSent.$current.withValue(sent) {
                    try await AgentTools.call(tool, arguments: args, session: session, control: control)
                }
            } catch {
                var extra: [String: Any] = [:]
                if let consent = (error as? AgentToolError)?.consent { extra["consent"] = consent.rawValue }
                return [.text(runResult(header, completed: completed, failedStep: index + 1,
                                        reason: error.localizedDescription, extra: extra))]
            }
            completed = index + 1
            if sent.write || step["possibleCommit"] as? Bool == true { lastPossibleCommit = index + 1 }
        }
        return [.text(runResult(header, completed: completed, failedStep: nil, reason: nil, lastPossibleCommit: lastPossibleCommit))]
    }

    private static func substitute(_ value: Any, params: [String: Any]) -> Any {
        if let object = value as? [String: Any] {
            if let param = object["param"] as? String, object.count == 1 { return params[param] ?? object }
            return object.mapValues { substitute($0, params: params) }
        }
        if let array = value as? [Any] { return array.map { substitute($0, params: params) } }
        return value
    }

    private static func runResult(
        _ header: [String: Any], completed: Int, failedStep: Int?, reason: String?,
        lastPossibleCommit: Int? = nil, extra: [String: Any] = [:]
    ) -> String {
        var result: [String: Any] = ["flow": header["flow"] ?? "", "completed": completed]
        if let lastPossibleCommit { result["lastPossibleCommit"] = lastPossibleCommit }
        if let failedStep {
            result["failedStep"] = failedStep
            result["reason"] = reason ?? ""
            result.merge(extra) { $1 }
        }
        return AgentTools.json(result)
    }
}
