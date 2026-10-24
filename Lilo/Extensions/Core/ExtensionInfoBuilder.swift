import Foundation

struct ExtensionInfo: Codable, Equatable {
    struct Icon: Codable, Equatable {
        let size: Int
        let url: String
    }

    let id: String
    let name: String
    let shortName: String
    let description: String
    let version: String
    let versionName: String?
    let enabled: Bool
    let type: String
    let installType: String
    let homepageUrl: String?
    let updateUrl: String?
    let optionsUrl: String?
    let icons: [Icon]
    let permissions: [String]
    let hostPermissions: [String]
    let offlineEnabled: Bool
    let disableReasons: [String]
}

struct ExtensionInfoBuilder {
    private static func extractIcons(from manifest: [String: Any]) -> [ExtensionInfo.Icon] {
        (manifest["icons"] as? [String: String] ?? [:])
            .compactMap { key, value in Int(key).map { ExtensionInfo.Icon(size: $0, url: value) } }
            .sorted { $0.size < $1.size }
    }

    static func buildFromManifest(
        manifest: [String: Any],
        id: String,
        enabled: Bool = true,
        installType: String = "normal"
    ) -> ExtensionInfo {
        let name = manifest["name"] as? String ?? "Unknown"
        let icons = extractIcons(from: manifest)
        let optionsUrl: String? = {
            if let ui = manifest["options_ui"] as? [String: Any], let p = ui["page"] as? String { return p }
            return manifest["options_page"] as? String
        }()
        return ExtensionInfo(
            id: id,
            name: name,
            shortName: manifest["short_name"] as? String ?? name,
            description: manifest["description"] as? String ?? "",
            version: manifest["version"] as? String ?? "0.0.1",
            versionName: manifest["version_name"] as? String,
            enabled: enabled,
            type: "extension",
            installType: installType,
            homepageUrl: manifest["homepage_url"] as? String,
            updateUrl: manifest["update_url"] as? String,
            optionsUrl: optionsUrl,
            icons: icons,
            permissions: manifest["permissions"] as? [String] ?? [],
            hostPermissions: manifest["host_permissions"] as? [String] ?? [],
            offlineEnabled: manifest["offline_enabled"] as? Bool ?? false,
            disableReasons: []
        )
    }
}
