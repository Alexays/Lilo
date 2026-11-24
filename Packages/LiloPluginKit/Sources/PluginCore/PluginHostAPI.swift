import Foundation

/// A tab as a plugin sees it: no page content, no engine handle.
public struct PluginTab: Equatable, Sendable {
    public let id: String
    public let url: String
    public let title: String

    public init(id: String, url: String, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }

    var json: JSONValue {
        .object(["id": .string(id), "url": .string(url), "title": .string(title)])
    }
}

/// What the app binds the host APIs to. PluginCore never sees a tab, a window or the settings
/// table, only these closures; tests pass recording ones.
public struct PluginHostAdapters: Sendable {
    public var listTabs: @Sendable () async -> [PluginTab]
    /// `nil` when no window can take the tab.
    public var openTab: @Sendable (URL) async -> PluginTab?
    public var settingValues: @Sendable (_ pluginID: String) async -> [String: JSONValue]
    public var setSettingValue: @Sendable (_ pluginID: String, _ name: String, _ value: JSONValue) async -> Void

    public init(
        listTabs: @escaping @Sendable () async -> [PluginTab] = { [] },
        openTab: @escaping @Sendable (URL) async -> PluginTab? = { _ in nil },
        settingValues: @escaping @Sendable (String) async -> [String: JSONValue] = { _ in [:] },
        setSettingValue: @escaping @Sendable (String, String, JSONValue) async -> Void = { _, _, _ in }
    ) {
        self.listTabs = listTabs
        self.openTab = openTab
        self.settingValues = settingValues
        self.setSettingValue = setSettingValue
    }
}

/// The plugin→host surface of one plugin: every method maps to one capability and answers
/// `capabilityNotGranted` without the grant, so a plugin reaches only what its manifest declared
/// and the user left granted.
public struct PluginHostAPI: Sendable {
    private let pluginID: String
    private let secrets: any PluginSecretStore
    private let adapters: PluginHostAdapters
    private let files: PluginFiles
    private let granted: @Sendable () async -> Set<PluginCapability>

    public init(
        pluginID: String, supportDirectory: URL, secrets: any PluginSecretStore, adapters: PluginHostAdapters,
        granted: @escaping @Sendable () async -> Set<PluginCapability>
    ) {
        self.pluginID = pluginID
        self.secrets = secrets
        self.adapters = adapters
        self.files = PluginFiles(root: supportDirectory)
        self.granted = granted
    }

    public static func capability(for method: String) -> PluginCapability? {
        switch method {
        case "settings.get", "settings.set", "secrets.get", "secrets.set", "secrets.delete": return .settingsStore
        case "tabs.list": return .tabsRead
        case "tabs.open": return .tabsOpen
        case "files.read", "files.write", "files.list": return .filesPluginDir
        default: return nil
        }
    }

    public func handle(_ method: String, params: JSONValue) async -> Result<JSONValue, PluginRequestError> {
        guard let required = Self.capability(for: method) else { return .failure(.methodNotFound) }
        guard await granted().contains(required) else { return .failure(.capabilityNotGranted) }
        let object: [String: JSONValue]
        if case .object(let given) = params { object = given } else { object = [:] }
        func string(_ key: String) -> String? {
            if case .string(let value)? = object[key] { return value }
            return nil
        }
        let missing = Result<JSONValue, PluginRequestError>.failure(.invalidParams("Missing or invalid params for \(method)"))
        do {
            switch method {
            case "settings.get":
                return .success(.object(await adapters.settingValues(pluginID)))
            case "settings.set":
                guard let name = string("name"), let value = object["value"] else { return missing }
                await adapters.setSettingValue(pluginID, name, value)
                return .success(.null)
            case "secrets.get":
                guard let name = string("name") else { return missing }
                return .success((try? secrets.secret(for: pluginID, name: name)).flatMap { $0 }.map { .string($0) } ?? .null)
            case "secrets.set":
                guard let name = string("name"), let value = string("value") else { return missing }
                try? secrets.setSecret(value, for: pluginID, name: name)
                return .success(.null)
            case "secrets.delete":
                guard let name = string("name") else { return missing }
                try? secrets.deleteSecret(for: pluginID, name: name)
                return .success(.null)
            case "tabs.list":
                return .success(.object(["tabs": .array(await adapters.listTabs().map(\.json))]))
            case "tabs.open":
                // Pages only: a plugin does not get `file:`, `javascript:` or an app scheme.
                guard let text = string("url"), let url = URL(string: text), url.host?.isEmpty == false,
                      ["http", "https"].contains(url.scheme?.lowercased()) else {
                    return .failure(.invalidParams("tabs.open needs an http or https url"))
                }
                guard let tab = await adapters.openTab(url) else {
                    return .failure(PluginRequestError(code: -32002, message: "No window can open the tab"))
                }
                return .success(tab.json)
            case "files.read":
                guard let path = string("path") else { return missing }
                return .success(.object(["content": .string(try files.read(path))]))
            case "files.write":
                guard let path = string("path"), let content = string("content") else { return missing }
                try files.write(path, content: content)
                return .success(.null)
            default:
                let entries = try files.list(string("path") ?? "")
                return .success(.object(["entries": .array(entries.map {
                    .object(["name": .string($0.name), "isDirectory": .bool($0.isDirectory)])
                })]))
            }
        } catch let error as PluginRequestError {
            return .failure(error)
        } catch {
            return .failure(.invalidParams("The call failed"))
        }
    }
}
