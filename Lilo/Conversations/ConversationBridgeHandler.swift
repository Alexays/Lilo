import AppKit
import UniformTypeIdentifiers

/// The chrome's side of agent conversations: starting one, prompting, answering, and what the Ask bar
/// and the Agents popover show.
@MainActor
final class ConversationBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = [
        "startConversation", "sendConversationPrompt", "cancelConversation", "answerConversation", "answerConversationQuestion",
        "setConversationMode", "setConversationConfig", "showConversation", "restoreConversation",
        "undoConversationFile", "loadAgentCatalog", "loadConversations", "chooseConversationProject",
        "openConversationChanges", "authenticateConversation", "answerConversationSignIn", "openConversationSignInTerminal",
        "loadConversationCommands",
        "searchConversationFiles", "previewConversationArtifact", "openConversationFile"
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
            guard let tab = await window.startConversation(agentId: agentId, cwd: cwd, activate: !background) else { return nil }
            await prompt(tab.id, payload, interrupt: false)
        case "sendConversationPrompt":
            guard let tabId else { return nil }
            await prompt(tabId, payload, interrupt: payload["interrupt"] as? Bool ?? false)
        case "cancelConversation":
            if let tabId { host.cancel(tabId) }
        case "answerConversation":
            guard let tabId, let requestId = payload["requestId"] as? String else { return nil }
            host.answer(tabId, requestId: requestId, optionId: payload["optionId"] as? String)
        case "answerConversationQuestion":
            guard let tabId, let requestId = payload["requestId"] as? String, let action = payload["action"] as? String else { return nil }
            host.answerQuestion(tabId, requestId: requestId, action: action, content: payload["content"] as? [String: Any])
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
                "agents": await host.catalog.runnableAgents().map { agent in
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
        case "answerConversationSignIn":
            if let tabId, let text = payload["text"] as? String { host.answerSignIn(tabId, text: text) }
        case "openConversationSignInTerminal":
            if let tabId { host.openSignInTerminal(tabId) }
        case "loadConversationCommands":
            if let tabId { host.loadCommands(tabId) }
        case "openConversationChanges":
            if let tabId { window.openChanges(forConversation: tabId) }
        case "openConversationFile":
            guard let tabId, let path = payload["path"] as? String, let cwd = host.conversations[tabId]?.cwd else { return nil }
            let bare = path.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
            let url = URL(fileURLWithPath: (bare as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            // The agent names the path: only a document opens, an app or a script is shown in Finder, never run.
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isExecutableKey, .isDirectoryKey])
            let document = values?.isDirectory == false && values?.isExecutable == false
                && [UTType.text, .image, .pdf].contains { values?.contentType?.conforms(to: $0) == true }
            if document, payload["reveal"] as? Bool != true {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
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
            .filter { !$0.hasPrefix(BuildIdentity.appSupportDirectory) }
        return ([active].compactMap { $0 } + terminals + conversations).filter { seen.insert($0).inserted }.prefix(7).map { $0 }
            + (seen.contains(NSHomeDirectory()) ? [] : [NSHomeDirectory()])
    }

    /// The text and what the chrome attached, as ACP content blocks: a tab's text, a selection, a screenshot
    /// when the agent takes images, a small text file whole and any other as a link. The message shows in the thread
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
                let label = unsafe kind == "screenshot" ? String(format: "Screenshot of %@".localized, tab.title)
                    : kind == "selection" ? String(format: "Selection from %@".localized, tab.title) : tab.title
                chips.append(["label": label, "uri": url.absoluteString])
                attachments.append((kind, nil, tab))
            }
        }
        guard host.announce(tabId, text: text, context: chips) else { return }
        var blocks: [[String: Any]] = [["type": "text", "text": text]] + images
        for (kind, path, tab) in attachments {
            if let path {
                let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                // A small text file goes along whole, as an @-mention does in Claude Code; a folder, a binary or a large file as a link.
                let contents = await Task.detached(priority: .userInitiated) { () -> String? in
                    guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }),
                          size <= 100_000, let data = try? Data(contentsOf: file) else { return nil }
                    return String(data: data, encoding: .utf8)
                }.value
                if let contents {
                    blocks.append(["type": "resource", "resource": ["uri": file.absoluteString, "text": contents, "mimeType": "text/plain"]])
                } else {
                    blocks.append(["type": "resource_link", "uri": file.absoluteString, "name": file.lastPathComponent])
                }
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
                guard let engine, let pixels = await engine.takeSnapshot(width: 1280)?.snapshotPixels,
                      let base64 = await Task.detached(priority: .userInitiated, operation: {
                          ScreenshotImageCodec.pngData(pixels)?.base64EncodedString()
                      }).value
                else { continue }
                blocks.append(["type": "image", "data": base64, "mimeType": "image/png", "uri": url.absoluteString])
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
