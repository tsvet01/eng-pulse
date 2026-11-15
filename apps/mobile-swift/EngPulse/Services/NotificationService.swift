import Foundation
import UserNotifications
import UIKit

// MARK: - Notification Service
@MainActor
class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    @Published var isAuthorized = false
    @Published var fcmToken: String?

    private override init() {
        super.init()
    }

    static func pilotPush(api: PilotAPIClient, bundle: Bundle = .main) -> PilotPushModel {
        let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            .map { (try? Data(contentsOf: $0)) ?? Data() }
        let hasReceipt = bundle.appStoreReceiptURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return PilotPushModel(api: api, journal: PilotKeychain(service: "org.tsvetkov.eng-pulse.push-binding"),
            receiptDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("EngPulsePilotPush", isDirectory: true),
            environment: PilotPushEnvironment.resolve(profile: profile, storeReceipt: hasReceipt),
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            authorization: { prompt in
                let center = UNUserNotificationCenter.current()
                switch await center.notificationSettings().authorizationStatus {
                case .authorized: return true
                case .notDetermined, .provisional:
                    guard prompt else { return false }
                    return try await center.requestAuthorization(options: [.alert, .sound])
                default: return false
                }
            },
            register: { UIApplication.shared.registerForRemoteNotifications() },
            unregister: { UIApplication.shared.unregisterForRemoteNotifications() })
    }

    // MARK: - Authorization

    /// Request notification permissions
    func requestAuthorization() async -> Bool {
        guard PilotBuild.allowsLegacyServices else { return false }
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            isAuthorized = granted

            if granted {
                // Register for remote notifications
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }

            return granted
        } catch {
            print("Notification authorization error: \(error)")
            return false
        }
    }

    // MARK: - Token Management

    /// Called when APNs token is received
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard PilotBuild.allowsLegacyServices else { return }
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()

        // In a real app with Firebase, this would be converted to FCM token
        // For now, we'll use the APNs token directly
        self.fcmToken = token

        // Register token with backend
        Task {
            await registerTokenWithBackend(token)
        }
    }

    /// Register APNs token with backend
    private func registerTokenWithBackend(_ token: String) async {
        guard PilotBuild.allowsLegacyServices else { return }
        guard let url = URL(string: "https://us-central1-tsvet01.cloudfunctions.net/register-apns-token") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Detect if running in sandbox (debug) mode
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif

        let body: [String: Any] = [
            "token": token,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "sandbox": sandbox
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("APNs token registered with backend successfully")
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "no response"
                    print("Token registration failed: HTTP \(httpResponse.statusCode) - \(responseStr)")
                }
            }
        } catch {
            print("Failed to register APNs token: \(error)")
        }
    }

    // MARK: - Topic Subscription

    /// Subscribe to a notification topic (requires Firebase)
    func subscribeToTopic(_ topic: String) {
        // This would use Firebase Messaging in a real implementation
        print("Would subscribe to topic: \(topic)")
    }

    /// Unsubscribe from a notification topic (requires Firebase)
    func unsubscribeFromTopic(_ topic: String) {
        // This would use Firebase Messaging in a real implementation
        print("Would unsubscribe from topic: \(topic)")
    }

}

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: UNUserNotificationCenterDelegate {

    /// Handle notification when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if PilotBuild.allowsLegacyServices { return [.banner, .badge, .sound] }
        guard PilotBuild.isEnabled, notification.request.trigger is UNPushNotificationTrigger else { return [] }
        let feed = notification.request.content.userInfo["feed"] as? String
        let show = await MainActor.run { AppServices.shared.pilotAccountModel?.push?.canPresent(feed: feed) == true }
        return show ? [.banner, .sound] : []
    }

    /// Handle notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard PilotBuild.allowsLegacyServices else { completionHandler(); return }
        let userInfo = response.notification.request.content.userInfo

        // Extract article URL safely
        guard let articleUrl = userInfo["article_url"] as? String else {
            completionHandler()
            return
        }

        // Store URL in UserDefaults - ContentView will check on appear
        UserDefaults.standard.set(articleUrl, forKey: "pendingArticleUrl")

        // Post notification on main thread
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .didReceiveArticleNotification,
                object: nil,
                userInfo: ["url": articleUrl]
            )
            completionHandler()
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let didReceiveArticleNotification = Notification.Name("didReceiveArticleNotification")
}
