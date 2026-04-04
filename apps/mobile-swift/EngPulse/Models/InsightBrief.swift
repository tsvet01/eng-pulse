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
}
