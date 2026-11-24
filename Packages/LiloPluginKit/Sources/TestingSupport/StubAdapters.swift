import Foundation
import PluginCore

/// `PluginSecretStore` backed by a dictionary: the tests' second implementation of the port.
public final class InMemoryPluginSecretStore: PluginSecretStore, @unchecked Sendable {
    private var secrets: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(for pluginID: String, name: String) throws -> String? {
        lock.withLock { secrets["\(pluginID)\u{1f}\(name)"] }
    }

    public func setSecret(_ value: String, for pluginID: String, name: String) throws {
        lock.withLock { secrets["\(pluginID)\u{1f}\(name)"] = value }
    }

    public func deleteSecret(for pluginID: String, name: String) throws {
        lock.withLock { _ = secrets.removeValue(forKey: "\(pluginID)\u{1f}\(name)") }
    }
}

/// Records `schedule`/`cancel` calls and fires jobs by hand.
public final class RecordingPluginScheduler: PluginScheduler, @unchecked Sendable {
    public private(set) var delays: [String: TimeInterval] = [:]
    public private(set) var cancelled: [String] = []
    private var pending: [String: @Sendable (String) -> Void] = [:]
    private let lock = NSLock()

    public init() {}

    public func schedule(_ jobID: String, after delay: TimeInterval, fire: @escaping @Sendable (String) -> Void) {
        lock.withLock {
            delays[jobID] = delay
            pending[jobID] = fire
        }
    }

    public func cancel(_ jobID: String) {
        lock.withLock {
            pending.removeValue(forKey: jobID)
            cancelled.append(jobID)
        }
    }

    /// Runs the job's fire callback as if its time came.
    public func fire(_ jobID: String) {
        let fire = lock.withLock { pending.removeValue(forKey: jobID) }
        fire?(jobID)
    }
}
