import Foundation

@main
struct BriefContractCheck {
    static func main() throws {
        let paths = CommandLine.arguments.dropFirst()
        precondition(!paths.isEmpty, "Pass generated brief fixture paths")
        for path in paths {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let payload = envelope["payload"] as! [String: Any]
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            let decoded = try JSONDecoder().decode(InsightBrief.self, from: payloadData)
            precondition(decoded.keyIdea == (payload["key_idea"] as? String ?? ""))
            precondition(decoded.whyItMatters == (payload["why_it_matters"] as? String ?? ""))
            precondition(decoded.deepDive == payload["deep_dive"] as? String)
            precondition(decoded.whatToChange == payload["what_to_change"] as? String)
            let meta = payload["meta"] as? [String: Any]
            precondition(decoded.meta?.confidence == meta?["confidence"] as? Double)
            precondition(decoded.meta?.category == meta?["category"] as? String)
            print("Decoded \(URL(fileURLWithPath: path).lastPathComponent) with the app's InsightBrief model")
        }
    }
}
