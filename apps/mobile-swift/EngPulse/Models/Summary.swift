import Foundation

// MARK: - Summary Model
struct Summary: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let url: String
    let summary: String
    let keyPoints: [String]
    let source: String
    let publishedAt: Date
    let category: Category
    let readTimeMinutes: Int

    enum CodingKeys: String, CodingKey {
        case id, title, url, summary
        case keyPoints = "key_points"
        case source
        case publishedAt = "published_at"
        case category
        case readTimeMinutes = "read_time_minutes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        summary = try container.decode(String.self, forKey: .summary)
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        source = try container.decode(String.self, forKey: .source)
        category = try container.decodeIfPresent(Category.self, forKey: .category) ?? .general
        readTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .readTimeMinutes) ?? 5

        // Parse date string
        let dateString = try container.decode(String.self, forKey: .publishedAt)
        let formatter = ISO8601DateFormatter()
        publishedAt = formatter.date(from: dateString) ?? Date()
    }

    // For creating test/preview data
    init(
        id: String,
        title: String,
        url: String,
        summary: String,
        keyPoints: [String],
        source: String,
        publishedAt: Date,
        category: Category,
        readTimeMinutes: Int
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.summary = summary
        self.keyPoints = keyPoints
        self.source = source
        self.publishedAt = publishedAt
        self.category = category
        self.readTimeMinutes = readTimeMinutes
    }
}

// MARK: - Category
enum Category: String, Codable, CaseIterable {
    case engineering
    case product
    case leadership
    case culture
    case process
    case general

    var displayName: String {
        rawValue.capitalized
    }

    var iconName: String {
        switch self {
        case .engineering: return "hammer.fill"
        case .product: return "shippingbox.fill"
        case .leadership: return "person.3.fill"
        case .culture: return "heart.fill"
        case .process: return "gearshape.fill"
        case .general: return "doc.text.fill"
        }
    }
}

// MARK: - Preview Data
extension Summary {
    static let preview = Summary(
        id: "1",
        title: "Building Scalable Systems at Scale",
        url: "https://example.com/article",
        summary: "An in-depth look at how modern tech companies build and maintain scalable systems that handle millions of requests.",
        keyPoints: [
            "Use horizontal scaling over vertical",
            "Implement proper caching strategies",
            "Monitor and measure everything"
        ],
        source: "Pragmatic Engineer",
        publishedAt: Date(),
        category: .engineering,
        readTimeMinutes: 8
    )

    static let previewList: [Summary] = [
        .preview,
        Summary(
            id: "2",
            title: "Product Management Best Practices",
            url: "https://example.com/pm",
            summary: "Essential practices for product managers in tech companies.",
            keyPoints: ["Focus on outcomes", "Talk to customers"],
            source: "Lenny's Newsletter",
            publishedAt: Date().addingTimeInterval(-86400),
            category: .product,
            readTimeMinutes: 6
        )
    ]
}
