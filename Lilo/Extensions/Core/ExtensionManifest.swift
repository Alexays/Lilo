import Foundation

/// Parsed Chrome Manifest V3 representation.
struct ExtensionManifest: Sendable, Decodable {

    let manifestVersion: Int
    let name: String
    let version: String
    let defaultLocale: String?
    let permissions: [String]?
    let hostPermissions: [String]?
    /// Every `content_scripts[].matches` pattern: Chrome grants these hosts at install.
    let contentScriptMatches: [String]
    /// `externally_connectable.matches`: WebKit only lets those pages message the extension once granted.
    let externallyConnectableMatches: [String]

    private struct ContentScript: Decodable {
        let matches: [String]?
    }

    private struct ExternallyConnectable: Decodable {
        let matches: [String]?
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case name
        case version
        case defaultLocale = "default_locale"
        case permissions
        case hostPermissions = "host_permissions"
        case contentScripts = "content_scripts"
        case externallyConnectable = "externally_connectable"
    }

    /// Lenient decoding: real-world manifests sometimes carry `manifest_version` as a stringified
    /// number, and a missing `name`/`version` should surface as a precise "required field missing"
    /// from `validate()` rather than an opaque `DecodingError` thrown before validation runs.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intValue = try? container.decode(Int.self, forKey: .manifestVersion) {
            manifestVersion = intValue
        } else if let stringValue = try? container.decode(String.self, forKey: .manifestVersion),
                  let parsed = Int(stringValue) {
            manifestVersion = parsed
        } else {
            manifestVersion = 0 // validate() rejects anything but 3
        }
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        if let stringVersion = try? container.decode(String.self, forKey: .version) {
            version = stringVersion
        } else if let numericVersion = try? container.decode(Double.self, forKey: .version) {
            version = String(numericVersion)
        } else {
            version = ""
        }
        defaultLocale = try? container.decodeIfPresent(String.self, forKey: .defaultLocale)
        permissions = try? container.decodeIfPresent([String].self, forKey: .permissions)
        hostPermissions = try? container.decodeIfPresent([String].self, forKey: .hostPermissions)
        let contentScripts = (try? container.decodeIfPresent([ContentScript].self, forKey: .contentScripts)) ?? []
        contentScriptMatches = contentScripts.flatMap { $0.matches ?? [] }
        externallyConnectableMatches = (try? container.decodeIfPresent(ExternallyConnectable.self, forKey: .externallyConnectable))?
            .flatMap(\.matches) ?? []
    }
}

// MARK: - Validation

extension ExtensionManifest {

    /// Validate that the manifest meets minimum MV3 requirements.
    func validate() throws {
        guard manifestVersion == 3 else { throw ExtensionError.unsupportedManifestVersion(manifestVersion) }
        guard !name.isEmpty else { throw ExtensionError.missingRequiredField("name") }
        guard !version.isEmpty else { throw ExtensionError.missingRequiredField("version") }
    }
}

/// Errors related to extension loading and validation.
enum ExtensionError: Error, LocalizedError {
    case manifestNotFound(String)
    case manifestParseError(String)
    case unsupportedManifestVersion(Int)
    case missingRequiredField(String)
    case downloadFailed(String)
    case invalidExtensionArchive(String)

    var errorDescription: String? {
        switch self {
        case .manifestNotFound(let p):           return "manifest.json not found at \(p)"
        case .manifestParseError(let d):         return "Failed to parse manifest.json: \(d)"
        case .unsupportedManifestVersion(let v): return "Unsupported manifest version \(v); only MV3 is supported"
        case .missingRequiredField(let f):       return "Required manifest field missing: \(f)"
        case .downloadFailed(let d):             return "Failed to download extension: \(d)"
        case .invalidExtensionArchive(let d):    return "Invalid extension archive: \(d)"
        }
    }
}
