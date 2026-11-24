import Foundation

/// A host API a plugin may call. Declared in the manifest, granted per capability at enable
/// time and revocable in the panel; a capability the host does not know rejects the manifest.
public enum PluginCapability: String, CaseIterable, Codable, Sendable {
    case tabsRead = "tabs:read"
    case tabsOpen = "tabs:open"
    case pageRead = "page:read"
    case pageAct = "page:act"
    case schedule = "schedule"
    case settingsStore = "settings:store"
    case uiSurface = "ui:surface"
    case filesPluginDir = "files:plugin-dir"
}

/// How a plugin-contributed tool's side effects are gated; `commit` and `irreversible` go
/// through the consent choke point like a core tool.
public enum PluginConsentTier: String, CaseIterable, Codable, Sendable {
    case read = "read"
    case reversibleWrite = "reversible-write"
    case commit = "commit"
    case irreversible = "irreversible"
}

/// Why a plugin's manifest did not load. `reason` is the user-facing string the panel shows.
public enum PluginManifestError: Error, Equatable, Sendable {
    case unreadableManifest
    case invalidJSON
    case unknownKey(String)
    case invalidField(String)
    case unsupportedSchemaVersion(Int)
    case unsupportedProtocolVersion(Int)
    case invalidPluginID(String)
    case unknownCapability(String)
    case entryNotExecutable(String)

    public var reason: String {
        switch self {
        case .unreadableManifest: return "lilo-plugin.json is missing or unreadable"
        case .invalidJSON: return "lilo-plugin.json is not a JSON object"
        case .unknownKey(let key): return "unknown key \"\(key)\""
        case .invalidField(let field): return "missing or invalid \"\(field)\""
        case .unsupportedSchemaVersion(let version): return "unsupported schemaVersion \(version)"
        case .unsupportedProtocolVersion(let version): return "unsupported protocolVersion \(version)"
        case .invalidPluginID(let id): return "invalid id \"\(id)\" (expected reverse-DNS like com.example.name)"
        case .unknownCapability(let capability): return "unknown capability \"\(capability)\""
        case .entryNotExecutable(let entry): return "entry \"\(entry)\" is not executable"
        }
    }
}

/// The `lilo-plugin.json` at a plugin folder's root, validated strictly at load: an unknown
/// key or capability rejects the plugin rather than surprising it at runtime.
public struct PluginManifest: Codable, Equatable, Sendable {
    public static let fileName = "lilo-plugin.json"
    public static let supportedSchemaVersion = 1
    public static let supportedProtocolVersion = 1

    public let schemaVersion: Int
    public let protocolVersion: Int
    public let id: String
    public let title: String
    public let version: String
    /// Executable path relative to the plugin folder; the sidecar's working directory is the folder.
    public let entry: String
    public let capabilities: [PluginCapability]
    public let contributes: Contributes

    public struct Contributes: Codable, Equatable, Sendable {
        public let tools: [Tool]
        public let settings: [Setting]

        public init(tools: [Tool] = [], settings: [Setting] = []) {
            self.tools = tools
            self.settings = settings
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A plugin may contribute only one kind.
            tools = try container.decodeIfPresent([Tool].self, forKey: .tools) ?? []
            settings = try container.decodeIfPresent([Setting].self, forKey: .settings) ?? []
        }
    }

    /// A tool the agent surface merges in while the plugin is enabled.
    public struct Tool: Codable, Equatable, Sendable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
        /// Absent means `read`: the least privilege.
        public let consent: PluginConsentTier?

        public var consentTier: PluginConsentTier { consent ?? .read }

        public init(name: String, description: String, inputSchema: JSONValue = .object([:]), consent: PluginConsentTier? = nil) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.consent = consent
        }
    }

    /// A form field the panel renders; `default` holds only the JSON scalar types the wire
    /// `PluginSettingSpec` allows (string, number, boolean).
    public struct Setting: Codable, Equatable, Sendable {
        public let name: String
        public let type: SettingType
        public let title: String
        public let options: [String]?
        public let `default`: JSONValue?
        public let required: Bool?

        public init(name: String, type: SettingType, title: String, options: [String]? = nil, default: JSONValue? = nil, required: Bool? = nil) {
            self.name = name
            self.type = type
            self.title = title
            self.options = options
            self.default = `default`
            self.required = required
        }
    }

    public enum SettingType: String, Codable, Sendable {
        case text, password, dropdown, toggle, number
    }

    public init(schemaVersion: Int, protocolVersion: Int, id: String, title: String, version: String, entry: String, capabilities: [PluginCapability] = [], contributes: Contributes = Contributes()) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.id = id
        self.title = title
        self.version = version
        self.entry = entry
        self.capabilities = capabilities
        self.contributes = contributes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        version = try container.decode(String.self, forKey: .version)
        entry = try container.decode(String.self, forKey: .entry)
        capabilities = try container.decodeIfPresent([PluginCapability].self, forKey: .capabilities) ?? []
        contributes = try container.decodeIfPresent(Contributes.self, forKey: .contributes) ?? Contributes()
    }

    private static let topLevelKeys: Set<String> = [
        "schemaVersion", "protocolVersion", "id", "title", "version", "entry", "capabilities", "contributes"
    ]
    private static let contributesKeys: Set<String> = ["tools", "settings"]
    private static let toolKeys: Set<String> = ["name", "description", "inputSchema", "consent"]
    private static let settingKeys: Set<String> = ["name", "type", "title", "options", "default", "required"]

    /// Loads and validates `lilo-plugin.json` in `pluginRoot`. Throws `PluginManifestError`.
    public static func load(at pluginRoot: URL) throws -> PluginManifest {
        let file = pluginRoot.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file) else { throw PluginManifestError.unreadableManifest }
        guard let raw = try? JSONSerialization.jsonObject(with: data), let object = raw as? [String: Any] else {
            throw PluginManifestError.invalidJSON
        }
        try validateKeys(object)
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as DecodingError {
            throw PluginManifestError.invalidField(Self.fieldName(of: error))
        } catch {
            throw PluginManifestError.invalidJSON
        }
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw PluginManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard manifest.protocolVersion == supportedProtocolVersion else {
            throw PluginManifestError.unsupportedProtocolVersion(manifest.protocolVersion)
        }
        guard manifest.id.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidPluginID(manifest.id)
        }
        // The entry must resolve inside the plugin folder to an executable file.
        let entryURL = pluginRoot.appendingPathComponent(manifest.entry).standardizedFileURL
        let rootPath = pluginRoot.standardizedFileURL.path + "/"
        guard entryURL.path.hasPrefix(rootPath) else { throw PluginManifestError.invalidField("entry") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: entryURL.path) else {
            throw PluginManifestError.entryNotExecutable(manifest.entry)
        }
        return manifest
    }

    /// Rejects any key the schema does not know, at every level, before the typed decode runs:
    /// the error names the key, which a DecodingError cannot.
    private static func validateKeys(_ object: [String: Any]) throws {
        for key in object.keys where !topLevelKeys.contains(key) { throw PluginManifestError.unknownKey(key) }
        for required in ["schemaVersion", "protocolVersion", "id", "title", "version", "entry"]
        where object[required] == nil { throw PluginManifestError.invalidField(required) }
        if let capabilities = object["capabilities"] {
            guard let list = capabilities as? [String] else { throw PluginManifestError.invalidField("capabilities") }
            for name in list where PluginCapability(rawValue: name) == nil {
                throw PluginManifestError.unknownCapability(name)
            }
        }
        guard let contributes = object["contributes"] else { return }
        guard let contributes = contributes as? [String: Any] else { throw PluginManifestError.invalidField("contributes") }
        for key in contributes.keys where !contributesKeys.contains(key) { throw PluginManifestError.unknownKey(key) }
        if let raw = contributes["tools"] {
            guard let tools = raw as? [[String: Any]] else { throw PluginManifestError.invalidField("contributes.tools") }
            for tool in tools {
                for key in tool.keys where !toolKeys.contains(key) { throw PluginManifestError.unknownKey(key) }
                if let consent = tool["consent"] as? String, PluginConsentTier(rawValue: consent) == nil {
                    throw PluginManifestError.invalidField("contributes.tools.consent")
                }
            }
        }
        if let raw = contributes["settings"] {
            guard let settings = raw as? [[String: Any]] else { throw PluginManifestError.invalidField("contributes.settings") }
            for setting in settings {
                for key in setting.keys where !settingKeys.contains(key) { throw PluginManifestError.unknownKey(key) }
                if let type = setting["type"] as? String, SettingType(rawValue: type) == nil {
                    throw PluginManifestError.invalidField("contributes.settings.type")
                }
                if let fallback = setting["default"] {
                    switch JSONValue(any: fallback) {
                    case .string, .number, .bool: break
                    default: throw PluginManifestError.invalidField("contributes.settings.default")
                    }
                }
            }
        }
    }

    private static func fieldName(of error: DecodingError) -> String {
        let path: [any CodingKey]
        switch error {
        case .keyNotFound(let key, _): return key.stringValue
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            path = context.codingPath
        @unknown default: path = []
        }
        return path.last?.stringValue ?? "manifest"
    }
}
