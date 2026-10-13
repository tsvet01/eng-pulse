import Foundation

struct InsightBriefMeta: Codable {
    let confidence: Double?
    let category: String?
}

struct InsightBrief: Codable {
    let keyIdea: String
    let whyItMatters: String
    let whatToChange: String?
    let deepDive: String
    let meta: InsightBriefMeta?

    enum CodingKeys: String, CodingKey {
        case keyIdea = "key_idea"
        case whyItMatters = "why_it_matters"
        case whatToChange = "what_to_change"
        case deepDive = "deep_dive"
        case meta
    }

    /// Single decode point for the insight-brief JSON payload, shared by the
    /// article screen and the speech pipeline so both parse identically.
    static func decode(from content: String) -> InsightBrief? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(InsightBrief.self, from: data)
    }
}

extension InsightBrief {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyIdea = try values.decodeIfPresent(String.self, forKey: .keyIdea) ?? ""
        whyItMatters = try values.decodeIfPresent(String.self, forKey: .whyItMatters) ?? ""
        whatToChange = try values.decodeIfPresent(String.self, forKey: .whatToChange)
        deepDive = try values.decode(String.self, forKey: .deepDive)
        meta = try values.decodeIfPresent(InsightBriefMeta.self, forKey: .meta)
    }
}
