import Foundation

extension ConversationHost {
    /// One agent as the chrome's `BridgeAgentInfo`, with what its last start or check found.
    func agentPayload(_ agent: ACPAgentCatalog.Agent) -> [String: Any] {
        var data: [String: Any] = ["id": agent.id, "name": agent.name, "description": agent.description]
        if case .command = agent.distribution {
            data["featured"] = true
            data["command"] = true
        } else if ACPAgentCatalog.featured.contains(where: { $0.id == agent.id }) {
            data["featured"] = true
        }
        if let icon = catalog.iconDataURL(for: agent.id) { data["icon"] = icon }
        if let record = readiness.record(for: agent.id) { data["readiness"] = record.payload }
        if readiness.checking.contains(agent.id) { data["checking"] = true }
        return data
    }

    /// Every window shows the agent's new record, or that it is being checked.
    func broadcastReadiness(_ agentId: String) {
        var data: [String: Any] = ["agentId": agentId, "checking": readiness.checking.contains(agentId)]
        if let record = readiness.record(for: agentId) { data["readiness"] = record.payload }
        for window in context?.windows.windows ?? [] {
            window.bridgeRouter.send(event: "agentReadiness", data: data)
        }
    }
}
