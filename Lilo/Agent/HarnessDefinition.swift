import Foundation

/// One agent app Lilo can register its MCP server with: where it lives, where its configuration is and which
/// first-party page the shape of that configuration comes from. A new harness is a row of `all`.
struct HarnessDefinition: Equatable, Sendable {
    /// How the server is added to the client, with the file `connectedClients` reads back, relative to the home.
    enum Config: Equatable, Sendable {
        /// `claude mcp add` owns the file; Lilo only reads it.
        case claudeCLI(store: String)
        /// `mcpServers.lilo`, merged into the file's other keys.
        case json(path: String)
        /// A `[mcp_servers.lilo]` table, replaced in place.
        case toml(path: String)

        var path: String {
            switch self {
            case .claudeCLI(let path), .json(let path), .toml(let path): path
            }
        }
    }

    /// What says the client is installed. At least one must be set: a row nobody can detect is never shown.
    struct Detect: Equatable, Sendable {
        var bundleID: String?
        /// The command-line tool, looked up in `~/.local/bin`, `binaryExtra` and the Homebrew prefixes.
        var binary: String?
        /// Where the tool's installer also puts it, relative to the home.
        var binaryExtra: [String] = []
        /// Folders the tool leaves in the home (relative), for an install elsewhere.
        var folders: [String] = []
    }

    let id: String
    let config: Config
    let detect: Detect
    /// The agent's handshake names (lowercased), exact or by prefix.
    let handshakes: [String]
    let handshakePrefixes: [String]
    /// The first-party page the configuration shape comes from, and the day it was last checked against it.
    let docsURL: String
    let verified: String
    /// What the settings page says after Connect: a literal, so the native strings check finds it.
    let added: @Sendable () -> String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    var rawValue: String { id }

    init?(rawValue: String) {
        guard let found = Self.all.first(where: { $0.id == rawValue }) else { return nil }
        self = found
    }

    /// The client behind the name an agent gives when it connects ("claude-ai" is Claude Desktop).
    init?(clientName: String) {
        let lowered = clientName.lowercased()
        guard let found = Self.all.first(where: { $0.handshakes.contains(lowered) || $0.handshakePrefixes.contains(where: lowered.hasPrefix) }) else { return nil }
        self = found
    }

    private init(id: String, config: Config, detect: Detect, handshakes: [String], handshakePrefixes: [String] = [],
                 docsURL: String, verified: String, added: @escaping @Sendable () -> String) {
        self.id = id
        self.config = config
        self.detect = detect
        self.handshakes = handshakes
        self.handshakePrefixes = handshakePrefixes
        self.docsURL = docsURL
        self.verified = verified
        self.added = added
    }

    static let claudeCode = Self(
        id: "claudeCode",
        // `claude mcp add --scope user` keeps its servers in ~/.claude.json.
        config: .claudeCLI(store: ".claude.json"),
        detect: Detect(binary: "claude", binaryExtra: [".claude/local/claude"], folders: [".claude"]),
        handshakes: ["claude-code"],
        docsURL: "https://code.claude.com/docs/en/mcp", verified: "2026-11-21",
        added: { "Added Lilo to Claude Code".localized })

    static let claudeDesktop = Self(
        id: "claudeDesktop",
        config: .json(path: "Library/Application Support/Claude/claude_desktop_config.json"),
        detect: Detect(bundleID: "com.anthropic.claudefordesktop"),
        handshakes: ["claude-ai"], handshakePrefixes: ["local-agent-mode-"],
        docsURL: "https://modelcontextprotocol.io/quickstart/user", verified: "2026-11-21",
        added: { "Added Lilo to Claude Desktop: quit and reopen Claude to load it".localized })

    static let codex = Self(
        id: "codex",
        config: .toml(path: ".codex/config.toml"),
        detect: Detect(bundleID: "com.openai.codex", binary: "codex", folders: [".codex"]),
        handshakes: ["codex", "codex-mcp-client"],
        docsURL: "https://developers.openai.com/codex/mcp", verified: "2026-11-21",
        added: { "Added Lilo to Codex".localized })

    static let cursor = Self(
        id: "cursor",
        config: .json(path: ".cursor/mcp.json"),
        detect: Detect(bundleID: "com.todesktop.230313mzl4w4u92"),
        handshakes: ["cursor", "cursor-vscode"],
        docsURL: "https://cursor.com/docs/context/mcp", verified: "2026-11-21",
        added: { "Added Lilo to Cursor".localized })

    /// In the order the settings page lists them.
    static let all = [claudeCode, claudeDesktop, codex, cursor]
}
