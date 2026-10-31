import Network
import WebKit

// MARK: - Permission origin key

/// Origin keys for `SitePermissionStore` and its callers. Default-port origins (`WKSecurityOrigin.port` is 0) must keep the
/// plain `scheme://host` key that stored grants use; a non-default port makes a distinct grant.
enum PermissionOriginKey {
    /// `scheme://host` when `port` is 0 or the scheme's default (80/http, 443/https), `scheme://host:port` otherwise.
    static func build(scheme: String, host: String, port: Int) -> String {
        guard port != 0, port != defaultPort(forScheme: scheme) else {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    private static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

extension WKSecurityOrigin {
    var permissionOriginKey: String {
        PermissionOriginKey.build(scheme: self.`protocol`, host: host, port: port)
    }

    /// A secure context in the spec's sense (https, file or loopback): the only origins allowed to ask
    /// for powerful features such as location and notifications.
    var isPotentiallyTrustworthy: Bool {
        let host = host.lowercased()
        return self.`protocol` == "https" || self.`protocol` == "file" || host == "localhost" || host.hasSuffix(".localhost")
            || host == "::1" || host == "[::1]" || IPv4Address(host).map { $0.rawValue.first == 127 } == true
    }
}

extension WKFrameInfo {
    /// The origin a frame's request is asked and stored under: its page's, as browsers delegate a frame's request to the top.
    var permissionOriginKey: String {
        guard !isMainFrame, let url = webView?.url, let scheme = url.scheme, let host = url.host, !host.isEmpty else {
            return securityOrigin.permissionOriginKey
        }
        return PermissionOriginKey.build(scheme: scheme, host: host, port: url.port ?? 0)
    }
}
