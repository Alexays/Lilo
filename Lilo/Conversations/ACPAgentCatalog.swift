import CryptoKit
import Foundation
import os

/// The agents people can talk to, from the ACP registry, and how to start each one. The registry is
/// fetched only when someone picks an agent, and kept on disk for a day.
@MainActor
final class ACPAgentCatalog {
    struct Agent: Sendable, Equatable {
        enum Distribution: Sendable, Equatable {
            case npx(package: String, args: [String])
            case uvx(package: String, args: [String])
            case binary(archive: URL, cmd: String, args: [String], sha256: String)
        }

        let id: String
        let name: String
        let description: String
        let version: String
        let distribution: Distribution
    }

    struct LaunchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let registryURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!
    /// Offered first, in this order; also what Lilo knows without the registry.
    static let featured: [Agent] = [
        Agent(id: "claude-acp", name: "Claude Agent", description: "", version: "",
              distribution: .npx(package: "@agentclientprotocol/claude-agent-acp", args: [])),
        Agent(id: "codex-acp", name: "Codex", description: "", version: "",
              distribution: .npx(package: "@agentclientprotocol/codex-acp", args: [])),
        Agent(id: "gemini", name: "Gemini CLI", description: "", version: "",
              distribution: .npx(package: "@google/gemini-cli", args: ["--acp"])),
        Agent(id: "github-copilot-cli", name: "Copilot", description: "", version: "",
              distribution: .npx(package: "@github/copilot", args: ["--acp"]))
    ]
    private static let logger = Logger(liloCategory: "acp-catalog")
    private static let maxAge: TimeInterval = 24 * 3600

    private let directory: URL
    private(set) var agents: [Agent] = ACPAgentCatalog.featured
    private var loadedAt: Date?
    private var loading: Task<Void, Never>?
    private var shellPath: String?

    init(directory: URL) {
        self.directory = directory
    }

    func agent(id: String) -> Agent? { agents.first { $0.id == id } }

    /// The cached registry when it is recent, else a fresh one; the featured agents when neither is there.
    func load() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.maxAge { return }
        if let loading { return await loading.value }
        let task = Task { await refresh() }
        loading = task
        await task.value
        loading = nil
    }

    /// The icons the registry ships, saved next to it, as data URLs the chrome can show without a request.
    func iconDataURL(for id: String) -> String? {
        guard let data = try? Data(contentsOf: directory.appending(path: "icons/\(id).svg")) else { return nil }
        return "data:image/svg+xml;base64," + data.base64EncodedString()
    }

    private func refresh() async {
        let file = directory.appending(path: "registry.json")
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        var data = try? Data(contentsOf: file)
        if data == nil || modified.map({ Date().timeIntervalSince($0) >= Self.maxAge }) ?? true {
            if let (fresh, response) = try? await URLSession.shared.data(from: Self.registryURL),
               (response as? HTTPURLResponse)?.statusCode == 200, Self.parse(fresh) != nil {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? fresh.write(to: file, options: .atomic)
                data = fresh
                await saveIcons(fresh)
            }
        }
        if let data, let parsed = Self.parse(data) {
            let featuredIds = Self.featured.map(\.id)
            agents = parsed.sorted { a, b in
                let ia = featuredIds.firstIndex(of: a.id) ?? Int.max, ib = featuredIds.firstIndex(of: b.id) ?? Int.max
                return ia != ib ? ia < ib : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        loadedAt = Date()
    }

    private func saveIcons(_ registry: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: registry) as? [String: Any],
              let entries = object["agents"] as? [[String: Any]] else { return }
        let icons = directory.appending(path: "icons")
        try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                guard let id = entry["id"] as? String, let icon = (entry["icon"] as? String).flatMap(URL.init(string:)),
                      icon.scheme == "https" else { continue }
                group.addTask {
                    guard let (data, response) = try? await URLSession.shared.data(from: icon),
                          (response as? HTTPURLResponse)?.statusCode == 200, data.count < 64 * 1024 else { return }
                    try? data.write(to: icons.appending(path: "\(id).svg"), options: .atomic)
                }
            }
        }
    }

    nonisolated static func parse(_ data: Data) -> [Agent]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["agents"] as? [[String: Any]] else { return nil }
        let platform = "darwin-" + (Self.isAppleSilicon ? "aarch64" : "x86_64")
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                  let distribution = entry["distribution"] as? [String: Any] else { return nil }
            let resolved: Agent.Distribution
            if let binary = (distribution["binary"] as? [String: Any])?[platform] as? [String: Any],
               let archive = (binary["archive"] as? String).flatMap(URL.init(string:)), archive.scheme == "https",
               let cmd = binary["cmd"] as? String, let sha256 = binary["sha256"] as? String {
                resolved = .binary(archive: archive, cmd: cmd, args: binary["args"] as? [String] ?? [], sha256: sha256.lowercased())
            } else if let npx = distribution["npx"] as? [String: Any], let package = npx["package"] as? String {
                resolved = .npx(package: package, args: npx["args"] as? [String] ?? [])
            } else if let uvx = distribution["uvx"] as? [String: Any], let package = uvx["package"] as? String {
                resolved = .uvx(package: package, args: uvx["args"] as? [String] ?? [])
            } else {
                return nil
            }
            return Agent(id: id, name: name, description: entry["description"] as? String ?? "",
                         version: entry["version"] as? String ?? "", distribution: resolved)
        }
    }

    private nonisolated static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// The command that starts `agent`, with the user's shell PATH: Lilo started from the Finder has none of
    /// what `.zshrc` adds, where node and the agents usually are.
    func launch(_ agent: Agent) async throws -> (executable: URL, arguments: [String], environment: [String: String]) {
        var environment = ProcessInfo.processInfo.environment
        let path = await userPath()
        environment["PATH"] = path
        switch agent.distribution {
        case .npx(let package, let args):
            guard let npx = Self.find("npx", in: path) else {
                throw LaunchError(message: String(format: "%@ needs Node.js: install it from nodejs.org, then try again.".localized, agent.name))
            }
            return (URL(fileURLWithPath: npx), ["--yes", package] + args, environment)
        case .uvx(let package, let args):
            guard let uvx = Self.find("uvx", in: path) else {
                throw LaunchError(message: String(format: "%@ needs uv: install it from astral.sh/uv, then try again.".localized, agent.name))
            }
            return (URL(fileURLWithPath: uvx), [package] + args, environment)
        case .binary(let archive, let cmd, let args, let sha256):
            let executable = try await install(agent, archive: archive, cmd: cmd, sha256: sha256)
            return (executable, args, environment)
        }
    }

    private func userPath() async -> String {
        if let shellPath { return shellPath }
        let marker = "__LILO_PATH__"
        let output = await AgentClientConfig.run("/bin/zsh", ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 5).output ?? ""
        let parts = output.components(separatedBy: marker)
        let found = parts.count >= 3 ? parts[1] : ""
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let path = found.isEmpty ? fallback : found + ":" + fallback
        shellPath = path
        return path
    }

    private static func find(_ name: String, in path: String) -> String? {
        path.split(separator: ":").lazy.map { "\($0)/\(name)" }.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Downloads the agent's archive once per version, checks it against the registry's SHA-256 before
    /// anything is unpacked, and returns its command.
    private func install(_ agent: Agent, archive: URL, cmd: String, sha256: String) async throws -> URL {
        let target = directory.appending(path: "bin/\(agent.id)/\(agent.version.isEmpty ? sha256 : agent.version)")
        let executable = target.appending(path: cmd).standardizedFileURL
        guard executable.path.hasPrefix(target.standardizedFileURL.path + "/") else {
            throw LaunchError(message: String(format: "%@ could not be installed.".localized, agent.name))
        }
        if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        let (downloaded, response) = try await URLSession.shared.download(from: archive)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LaunchError(message: String(format: "%@ could not be downloaded.".localized, agent.name))
        }
        let digest = try await Task.detached { SHA256.hash(data: try Data(contentsOf: downloaded, options: .mappedIfSafe)) }.value
        guard digest.map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw LaunchError(message: String(format: "%@ did not match its checksum and was not installed.".localized, agent.name))
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let name = archive.lastPathComponent.lowercased()
        let status = name.hasSuffix(".zip")
            ? await AgentClientConfig.run("/usr/bin/ditto", ["-x", "-k", downloaded.path, target.path], timeout: 120).status
            : await AgentClientConfig.run("/usr/bin/tar", ["-xf", downloaded.path, "-C", target.path], timeout: 120).status
        guard status == 0, FileManager.default.isExecutableFile(atPath: executable.path) else {
            try? FileManager.default.removeItem(at: target)
            throw LaunchError(message: String(format: "%@ could not be installed.".localized, agent.name))
        }
        Self.logger.info("installed \(agent.id, privacy: .public) \(agent.version, privacy: .public)")
        return executable
    }
}
