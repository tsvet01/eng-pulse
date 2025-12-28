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

    // MARK: - Authorization

    /// Request notification permissions
    func requestAuthorization() async -> Bool {
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

    /// Check current authorization status
    func checkAuthorizationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    // MARK: - Token Management

    /// Called when APNs token is received
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("APNs token: \(token)")

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

    // MARK: - Notification Handling

    /// Handle received notification
    func handleNotification(_ userInfo: [AnyHashable: Any]) {
        print("Received notification: \(userInfo)")

        // Extract article URL if present
        if let articleUrl = userInfo["article_url"] as? String {
            print("Article URL: \(articleUrl)")
            // Could post a notification to navigate to the article
            NotificationCenter.default.post(
                name: .didReceiveArticleNotification,
                object: nil,
                userInfo: ["url": articleUrl]
            )
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: UNUserNotificationCenterDelegate {

    /// Handle notification when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .badge, .sound]
    }

    /// Handle notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        // Extract article URL safely before switching to main actor
        guard let articleUrl = userInfo["article_url"] as? String else {
            return
        }

        // Store URL in UserDefaults - ContentView will check on appear
        print("Storing pending articleUrl: \(articleUrl)")
        UserDefaults.standard.set(articleUrl, forKey: "pendingArticleUrl")

        // Also post notification for immediate handling if view is active
        await MainActor.run {
            NotificationCenter.default.post(
                name: .didReceiveArticleNotification,
                object: nil,
                userInfo: ["url": articleUrl]
            )
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let didReceiveArticleNotification = Notification.Name("didReceiveArticleNotification")
}
