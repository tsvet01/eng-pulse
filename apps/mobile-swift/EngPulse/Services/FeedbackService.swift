import Foundation
import FirebaseAuth

actor FeedbackService {
    static let shared = FeedbackService()

    private let endpointURL: URL

    private struct RequestBody: Encodable {
        let summaryUrl: String
        let feedback: String
        let promptVersion: String?

        enum CodingKeys: String, CodingKey {
            case summaryUrl = "summary_url"
            case feedback
            case promptVersion = "prompt_version"
        }
    }

    private init() {
        guard let url = URL(string: "https://us-central1-tsvet01.cloudfunctions.net/feedback-receiver") else {
            fatalError("Invalid feedback endpoint URL")
        }
        self.endpointURL = url
    }

    /// Upload feedback to Cloud Function. Fire-and-forget — errors are logged, not surfaced.
    /// Note: If auth hasn't completed yet (offline first launch), feedback is silently skipped.
    /// Local UserDefaults still captures it. Offline queuing deferred to future iteration.
    func submitFeedback(summaryURL: String, feedback: String, promptVersion: String?) async {
        guard let user = Auth.auth().currentUser else {
            print("FeedbackService: No authenticated user, skipping upload")
            return
        }

        do {
            let token = try await user.getIDToken()

            var request = URLRequest(url: endpointURL, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            request.httpBody = try JSONEncoder().encode(
                RequestBody(summaryUrl: summaryURL, feedback: feedback, promptVersion: promptVersion)
            )

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("FeedbackService: Server returned \(httpResponse.statusCode)")
            }
        } catch {
            print("FeedbackService: Upload failed: \(error.localizedDescription)")
        }
    }
}
