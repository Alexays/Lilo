import Foundation

/// One entry of the `agentAcpInstances` setting: a registry agent the user added to their list, or a
/// command of their own. A disabled entry stays resolvable so its conversations keep working.
struct ACPAgentInstance: Equatable, Sendable {
    enum Source: String, Sendable {
        case registry, command
    }

    /// Registry instances carry their registry id here; command instances get a unique one when added.
    var id: String
    var source: Source
    /// The name the list shows: the command's label, or the registry's name read when it was added.
    var name = ""
    /// A registry instance's agent id (equal to `id` while an agent has at most one instance).
    var registryId: String?
    /// A command instance's fields: the full path of an executable, one argument per line and
    /// `NAME=value` environment lines, as the editor takes them.
    var executable = ""
    var arguments = ""
    var environment = ""
    var enabled = true

    /// The `agentAcpInstances` setting as entries; malformed ones are dropped.
    static func list(from json: String?) -> [ACPAgentInstance] {
        guard let json, let entries = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let source = Source(rawValue: entry["source"] as? String ?? "") else { return nil }
            var instance = ACPAgentInstance(id: id, source: source)
            instance.name = entry["name"] as? String ?? ""
            instance.registryId = entry["registryId"] as? String
            instance.executable = entry["executable"] as? String ?? ""
            instance.arguments = entry["arguments"] as? String ?? ""
            instance.environment = entry["environment"] as? String ?? ""
            instance.enabled = entry["enabled"] as? Bool ?? true
            return instance
        }
    }

    static func json(_ instances: [ACPAgentInstance]) -> String {
        let entries: [[String: Any]] = instances.map { instance in
            var entry: [String: Any] = ["id": instance.id, "source": instance.source.rawValue, "enabled": instance.enabled]
            if !instance.name.isEmpty { entry["name"] = instance.name }
            if let registryId = instance.registryId { entry["registryId"] = registryId }
            if !instance.executable.isEmpty { entry["executable"] = instance.executable }
            if !instance.arguments.isEmpty { entry["arguments"] = instance.arguments }
            if !instance.environment.isEmpty { entry["environment"] = instance.environment }
            return entry
        }
        return (try? String(data: JSONSerialization.data(withJSONObject: entries, options: .sortedKeys), encoding: .utf8)) ?? "[]"
    }

    /// The single `customAgent` JSON as the list's first command entry, keeping its "custom" id so the
    /// conversations started with it still name an agent. Nil when there is no command to keep.
    static func migrate(customAgent json: String?) -> ACPAgentInstance? {
        guard let json, let fields = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: String] else { return nil }
        let executable = (fields["executable"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !executable.isEmpty else { return nil }
        return ACPAgentInstance(id: ACPAgentCatalog.customId, source: .command, name: fields["name"] ?? "",
                                executable: executable, arguments: fields["arguments"] ?? "",
                                environment: fields["environment"] ?? "", enabled: true)
    }
}
