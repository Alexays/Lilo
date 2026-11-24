import Foundation
import PluginCore

/// The stub plugin every host test drives: a `#!/bin/sh` sidecar speaking the protocol's
/// ndjson (no Node, no Python — `/bin/sh` and `sed` are everywhere).
public enum StubPlugin {
    /// Methods: `initialize` (protocolVersion 1 + one tool), `ping` (pong), `fail` (RPC
    /// error), `hang` (never answers: deadline tests), `exit` (ends: respawn tests).
    public static let sidecarScript = #"""
#!/bin/sh
while IFS= read -r line; do
    method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    [ -n "$id" ] || continue
    case "$method" in
        initialize)
            printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"tools\":[{\"name\":\"stub_ping\",\"description\":\"Stub tool\",\"inputSchema\":{\"type\":\"object\"},\"consent\":\"read\"}]}}"
            ;;
        ping)
            printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"pong\":true}}"
            ;;
        fail)
            printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32000,\"message\":\"stub failure\"}}"
            ;;
        hang) : ;;
        exit) exit 0 ;;
        *) printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}" ;;
    esac
done
"""#

    /// The manifest a plain stub plugin carries, merged with `overrides`.
    public static func manifestFields(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "schemaVersion": 1,
            "protocolVersion": 1,
            "id": "app.lilo.test.stub",
            "title": "Stub Plugin",
            "version": "1.0.0",
            "entry": "bin/stub.sh",
            "capabilities": ["settings:store"]
        ]
        for (key, value) in overrides { fields[key] = value }
        return fields
    }

    /// Writes a plugin folder (`lilo-plugin.json` + executable `bin/stub.sh`) and returns
    /// the validated manifest. `writeSidecar: false` leaves the entry missing, and
    /// `executable: false` writes it without the +x bit — both for rejection tests.
    @discardableResult
    public static func write(
        at folder: URL, manifest overrides: [String: Any] = [:], writeSidecar: Bool = true, executable: Bool = true
    ) throws -> PluginManifest {
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if writeSidecar {
            let script = bin.appendingPathComponent("stub.sh")
            try sidecarScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: script.path
            )
        }
        let data = try JSONSerialization.data(withJSONObject: manifestFields(overrides), options: .sortedKeys)
        try data.write(to: folder.appendingPathComponent(PluginManifest.fileName))
        return try PluginManifest.load(at: folder)
    }

    /// The sh sidecar's behavior, for an in-process `StubPluginTransport`: `initialize`
    /// gets the same reply the script gives; anything else answers like it does.
    public static func responder(
        tools: [JSONValue]? = nil
    ) -> @Sendable (StubPluginTransport, Data) -> Void {
        { transport, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String, let id = object["id"] else { return }
            let requestID = JSONValue(any: id)
            switch method {
            case "initialize":
                let toolList = tools ?? [.object([
                    "name": .string("stub_ping"), "description": .string("Stub tool"),
                    "inputSchema": .object(["type": .string("object")]), "consent": .string("read")
                ])]
                transport.emit([
                    "jsonrpc": .string("2.0"), "id": requestID,
                    "result": .object(["protocolVersion": .number(1), "tools": .array(toolList)])
                ])
            case "ping":
                transport.emit(["jsonrpc": .string("2.0"), "id": requestID, "result": .object(["pong": .bool(true)])])
            case "hang":
                break
            case "exit":
                transport.exit()
            default:
                transport.emit([
                    "jsonrpc": .string("2.0"), "id": requestID,
                    "error": .object(["code": .number(-32601), "message": .string("Method not found")])
                ])
            }
        }
    }
}
