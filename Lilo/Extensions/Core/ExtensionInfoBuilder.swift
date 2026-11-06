import Foundation
import UniformTypeIdentifiers

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

    /// Chrome's ExtensionInfo, the same shape for every management call and event. Nil optionals are omitted.
    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "shortName": shortName,
            "description": description,
            "version": version,
            "enabled": enabled,
            "type": type,
            "installType": installType,
            "icons": icons.map { ["size": $0.size, "url": $0.url] },
            "permissions": permissions,
            "hostPermissions": hostPermissions,
            "offlineEnabled": offlineEnabled,
            "disableReasons": disableReasons
        ]
        if let versionName { dict["versionName"] = versionName }
        if let homepageUrl { dict["homepageUrl"] = homepageUrl }
        if let updateUrl { dict["updateUrl"] = updateUrl }
        if let optionsUrl { dict["optionsUrl"] = optionsUrl }
        return dict
    }
}

struct ExtensionInfoBuilder {
    /// Data URLs: another extension's `chrome-extension://` URL loads only when it is web accessible.
    private static func extractIcons(from manifest: [String: Any], folder: URL) -> [ExtensionInfo.Icon] {
        let root = folder.resolvingSymlinksInPath().path + "/"
        return (manifest["icons"] as? [String: String] ?? [:])
            .compactMap { key, path in
                let file = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                // The manifest names the file: nothing outside the extension's folder is read.
                guard let size = Int(key), file.path.hasPrefix(root), let data = try? Data(contentsOf: file) else { return nil }
                let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "image/png"
                return ExtensionInfo.Icon(size: size, url: "data:\(type);base64,\(data.base64EncodedString())")
            }
            .sorted { $0.size < $1.size }
    }

    /// `folder` holds the extension's files, which its icons are read from.
    static func buildFromManifest(
        manifest: [String: Any],
        id: String,
        folder: URL,
        enabled: Bool = true,
        installType: String = "normal"
    ) -> ExtensionInfo {
        let name = manifest["name"] as? String ?? "Unknown"
        let icons = extractIcons(from: manifest, folder: folder)
        let optionsPage = (manifest["options_ui"] as? [String: Any])?["page"] as? String ?? manifest["options_page"] as? String
        let optionsUrl = optionsPage.map { "chrome-extension://\(id)/\($0.hasPrefix("/") ? String($0.dropFirst()) : $0)" }
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
