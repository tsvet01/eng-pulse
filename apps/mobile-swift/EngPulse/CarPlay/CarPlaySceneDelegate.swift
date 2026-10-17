import CarPlay
import Combine

/// CarPlay uses the same admitted account and playback as the phone.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var contentManager: CarPlayContentManager?
    private var accountObservation: AnyCancellable?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let services = AppServices.shared
        if PilotBuild.allowsLegacyServices {
            connect(interfaceController, appState: services.appState, tts: services.ttsService)
        } else {
            accountObservation = services.$pilotReader.sink { [weak self, weak interfaceController] context in
                guard let self, let interfaceController else { return }
                self.contentManager?.disconnect()
                self.contentManager = nil
                if let context {
                    self.connect(interfaceController, appState: context.appState, tts: context.ttsService)
                } else {
                    let item = CPListItem(text: "Sign in on your iPhone", detailText: "Connect your Eng Pulse pilot account to listen.")
                    item.isEnabled = false
                    interfaceController.setRootTemplate(CPListTemplate(title: "Eng Pulse",
                        sections: [CPListSection(items: [item])]), animated: false, completion: nil)
                }
            }
            Task { await services.pilotAccountModel?.restore() }
        }
    }

    private func connect(_ controller: CPInterfaceController, appState: AppState, tts: TTSService) {
        let manager = CarPlayContentManager(interfaceController: controller, appState: appState, ttsService: tts)
        contentManager = manager
        manager.connect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        accountObservation = nil
        contentManager?.disconnect()
        contentManager = nil
    }
}
