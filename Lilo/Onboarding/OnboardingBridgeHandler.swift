import Foundation

@MainActor
final class OnboardingBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = ["getOnboardingState", "setOnboardingStep", "completeOnboarding"]

    private weak var settingsStore: SettingsStore?
    private weak var bridgeRouter: BridgeRouter?

    init(settingsStore: SettingsStore, bridgeRouter: BridgeRouter) {
        self.settingsStore = settingsStore
        self.bridgeRouter = bridgeRouter
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let store = settingsStore else { return nil }
        switch message.action {
        case "getOnboardingState":
            bridgeRouter?.send(event: "onboardingState", data: [
                "show": store.shouldShowOnboarding, "step": store.onboardingStep, "usage": store.get("onboardingUsage") ?? "browse"
            ])
        case "setOnboardingStep":
            if let step = message.int("step") { store.onboardingStep = step }
        case "completeOnboarding":
            store.completeOnboarding()
            // The default-browser invite drawer must not follow the onboarding's own step.
            store.didPromptDefaultBrowser = true
        default:
            break
        }
        return nil
    }
}
