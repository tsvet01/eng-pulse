import CarPlay

// MARK: - CarPlay Scene Delegate
/// Entry point for the CarPlay scene, declared under
/// `CPTemplateApplicationSceneSessionRoleApplication` in Info.plist.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var contentManager: CarPlayContentManager?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let services = AppServices.shared
        let manager = CarPlayContentManager(
            interfaceController: interfaceController,
            appState: services.appState,
            ttsService: services.ttsService
        )
        contentManager = manager
        manager.connect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        contentManager?.disconnect()
        contentManager = nil
    }
}
