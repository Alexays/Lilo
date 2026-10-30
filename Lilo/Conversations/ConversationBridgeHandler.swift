import AppKit

/// The chrome's side of agent conversations: starting one, prompting, answering, and what the Ask bar
/// and the Agents popover show.
@MainActor
final class ConversationBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = [
        "startConversation", "sendConversationPrompt", "cancelConversation", "answerConversation",
        "setConversationMode", "setConversationConfig", "showConversation", "restoreConversation",
        "undoConversationFile", "loadAgentCatalog", "loadConversations", "chooseConversationProject",
        "openConversationChanges", "authenticateConversation", "searchConversationFiles", "previewConversationArtifact"
    ]

    private weak var window: MainWindowController?

    init(window: MainWindowController) {
        self.window = window
    }

    private var host: ConversationHost? { window?.context.conversations }

    func handle(message: BridgeMessage) async -> Any? {
        guard let window, let host else { return nil }
        let payload = message.payload
        let tabId = (payload["tabId"] as? String).flatMap(UUID.init(uuidString:))
        switch message.action {
        case "startConversation":
            guard let agentId = payload["agentId"] as? String, let cwd = payload["cwd"] as? String else { return nil }
            let background = payload["background"] as? Bool ?? false
            guard let tab = window.startConversation(agentId: agentId, cwd: cwd, ownCopy: payload["ownCopy"] as? Bool ?? false,
                                                     activate: !background) else { return nil }
            await prompt(tab.id, payload, interrupt: false)
        case "sendConversationPrompt":
            guard let tabId else { return nil }
            await prompt(tabId, payload, interrupt: payload["interrupt"] as? Bool ?? false)
        case "cancelConversation":
            if let tabId { host.cancel(tabId) }
        case "answerConversation":
            guard let tabId, let requestId = payload["requestId"] as? String else { return nil }
            host.answer(tabId, requestId: requestId, optionId: payload["optionId"] as? String)
        case "setConversationMode":
            if let tabId, let modeId = payload["modeId"] as? String { host.setMode(tabId, modeId: modeId) }
        case "setConversationConfig":
            if let tabId, let configId = payload["configId"] as? String, let value = payload["value"] {
                host.setConfigOption(tabId, configId: configId, value: value)
            }
        case "showConversation":
            if let tabId { host.show(tabId, in: window, visible: payload["visible"] as? Bool ?? true) }
        case "restoreConversation":
            if let tabId, let index = payload["checkpoint"] as? Int { host.restore(tabId, checkpoint: index) }
        case "undoConversationFile":
            if let tabId, let path = payload["path"] as? String, let index = payload["checkpoint"] as? Int {
                host.undo(tabId, path: path, checkpoint: index)
            }
        case "loadAgentCatalog":
            if payload["refresh"] as? Bool ?? false { await host.catalog.load() }
            window.bridgeRouter.send(event: "agentCatalog", data: [
                "agents": host.catalog.agents.map { agent in
                    var data: [String: Any] = ["id": agent.id, "name": agent.name, "description": agent.description]
                    if let icon = host.catalog.iconDataURL(for: agent.id) { data["icon"] = icon }
                    return data
                },
                "projects": projects(),
                "home": NSHomeDirectory()
            ])
        case "loadConversations":
            window.bridgeRouter.send(event: "conversationsChanged", data: ["conversations": host.summaries()])
        case "chooseConversationProject":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Choose".localized
            guard let parent = window.window, await panel.beginSheetModal(for: parent) == .OK, let url = panel.url else { return nil }
            window.bridgeRouter.send(event: "conversationProjectChosen", data: ["path": url.path])
        case "searchConversationFiles":
            guard let cwd = payload["cwd"] as? String, let query = payload["query"] as? String else { return nil }
            let files = await host.projectFiles.search(query, in: cwd)
            window.bridgeRouter.send(event: "conversationFiles", data: ["cwd": cwd, "query": query, "files": files])
        case "previewConversationArtifact":
            guard let tabId, let code = payload["code"] as? String else { return nil }
            window.previewArtifact(code, language: payload["language"] as? String ?? "html", forConversation: tabId)
        case "authenticateConversation":
            if let tabId, let methodId = payload["methodId"] as? String { host.authenticate(tabId, methodId: methodId) }
        case "openConversationChanges":
            if let tabId { window.openChanges(forConversation: tabId) }
        default:
            break
        }
        return nil
    }

    /// The folders a conversation can work in, most likely first: the active terminal's, then those of
    /// other terminals and past conversations, and the home folder, so there is always one.
    private func projects() -> [String] {
        guard let window else { return [] }
        var seen = Set<String>()
        let active = window.tabManager.activeTab.flatMap { $0.kind == .terminal || $0.kind == .agent ? $0.cwd : nil }
        let terminals = window.terminalSummaries().compactMap { ($0["tabId"] as? String).flatMap(UUID.init(uuidString:)) }
            .compactMap { window.context.browserState.durableTab(for: $0)?.tab.cwd }
        let conversations = window.context.conversations.conversations.values.map(\.cwd)
            .filter { !$0.contains("/Worktrees/") }
        return ([active].compactMap { $0 } + terminals + conversations).filter { seen.insert($0).inserted }.prefix(7).map { $0 }
            + (seen.contains(NSHomeDirectory()) ? [] : [NSHomeDirectory()])
    }

    /// The text and what the chrome attached, as ACP content blocks: a tab's text, a selection, a screenshot
    /// when the agent takes images, files as links the agent reads itself. The message shows in the thread
    /// at once, with its chips; reading the pages comes after, so sending never waits on a page.
    private func prompt(_ tabId: UUID, _ payload: [String: Any], interrupt: Bool) async {
        guard let window, let host else { return }
        let text = payload["text"] as? String ?? ""
        var attachments: [(kind: String, path: String?, tab: Tab)] = []
        var images: [[String: Any]] = []
        var chips: [[String: Any]] = []
        for attachment in payload["attachments"] as? [[String: Any]] ?? [] {
            let kind = attachment["kind"] as? String ?? ""
            if kind == "file", let path = attachment["path"] as? String {
                chips.append(["label": URL(fileURLWithPath: path).lastPathComponent, "uri": path])
                attachments.append((kind, path, Tab()))
                continue
            }
            if kind == "image", let data = attachment["data"] as? String, let mimeType = attachment["mimeType"] as? String {
                chips.append(["label": "Pasted image".localized, "uri": ""])
                images.append(["type": "image", "data": data, "mimeType": mimeType])
                continue
            }
            let ids: [UUID]
            if kind == "folder", let folderId = (attachment["folderId"] as? String).flatMap(UUID.init(uuidString:)),
               let spaceId = window.tabManager.currentSpaceId {
                ids = window.tabManager.sidebarTreeItems(forSpace: spaceId)
                    .filter { $0.kind == .tab && $0.parentFolderId == folderId }.map(\.itemId)
            } else {
                ids = [(attachment["tabId"] as? String).flatMap(UUID.init(uuidString:))].compactMap { $0 }
            }
            for id in ids {
                guard let tab = window.context.browserState.durableTab(for: id)?.tab, tab.kind == .web, let url = tab.url else { continue }
                let label = kind == "screenshot" ? String(format: "Screenshot of %@".localized, tab.title) : tab.title
                chips.append(["label": label, "uri": url.absoluteString])
                attachments.append((kind, nil, tab))
            }
        }
        guard host.announce(tabId, text: text, context: chips) else { return }
        var blocks: [[String: Any]] = [["type": "text", "text": text]] + images
        for (kind, path, tab) in attachments {
            if let path {
                blocks.append(["type": "resource_link", "uri": URL(fileURLWithPath: path).absoluteString, "name": URL(fileURLWithPath: path).lastPathComponent])
                continue
            }
            guard let url = tab.url else { continue }
            let engine = window.tabManager.engineTab(for: tab.id)
            switch kind {
            case "selection":
                guard let engine, let selection = try? await engine.wkWebView.callAsyncJavaScript(
                    "return String(getSelection())", arguments: [:], in: nil, contentWorld: AgentInput.world
                ) as? String, !selection.isEmpty else { continue }
                blocks.append(["type": "resource", "resource": ["uri": url.absoluteString, "text": selection, "mimeType": "text/plain"]])
            case "screenshot":
                guard let engine, let image = await engine.takeSnapshot(width: 1280),
                      let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { continue }
                blocks.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png", "uri": url.absoluteString])
            default:
                // A page's text when its engine is alive; a link the agent can open with Lilo's tools otherwise.
                if let engine, let pageText = try? await AgentTools.page(engine, "text", ["maxChars": 50_000]) as? String, !pageText.isEmpty {
                    blocks.append(["type": "resource", "resource": ["uri": url.absoluteString, "text": "# \(tab.title)\n\n\(pageText)", "mimeType": "text/markdown"]])
                } else {
                    blocks.append(["type": "resource_link", "uri": url.absoluteString, "name": tab.title])
                }
            }
        }
        host.send(tabId, blocks: blocks, interrupt: interrupt)
    }
}
