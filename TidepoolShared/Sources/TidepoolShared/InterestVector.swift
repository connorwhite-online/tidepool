import Foundation

// MARK: - Canonical Vocabulary

/// The canonical vocabulary shared between client and server.
/// Both sides must use the same tags in the same order for vector compatibility.
public enum InterestVocabulary {
    public static let tags: [String] = [
        // Venue types
        "dining", "restaurant", "cafe", "coffee", "bar", "nightlife", "fast_food",
        "fine_dining", "bakery", "grocery", "shopping", "mall", "bookstore",
        "wine_bar", "craft_beer", "cocktails", "brewery",

        // Activities & Recreation
        "outdoor", "nature", "park", "beach", "hiking", "fitness", "gym", "sports",
        "entertainment", "movies", "theater", "museum", "culture", "arts",
        "music", "live_music", "concerts",

        // Social & Lifestyle
        "social", "casual", "work", "study", "quiet", "family_friendly",
        "romantic", "business", "networking", "date_night", "all_ages",

        // Characteristics
        "convenient", "trendy", "local", "tourist", "hidden_gem", "popular",
        "affordable", "upscale", "budget", "luxury", "good_value",

        // Services & Amenities
        "wifi", "parking", "takeout", "delivery", "reservations", "pet_friendly",
        "accessible", "outdoor_seating", "drive_through",

        // Time & Frequency
        "daily", "weekly", "special_occasion", "regular", "frequent", "occasional",

        // Quality indicators
        "highly_rated", "recommended", "favorite", "must_visit", "avoid",

        // Mood & Context
        "relaxing", "energetic", "productive", "creative", "inspiring",
        "comfortable", "atmospheric", "cozy", "modern", "traditional",

        // Music Genres
        "rock", "pop", "hip_hop", "rap", "electronic", "dance", "jazz", "blues",
        "classical", "country", "folk", "metal", "r_and_b", "soul", "funk",
        "reggae", "latin", "world", "indie", "alternative", "punk", "ambient",

        // Music Sub-genres
        "house", "techno", "trance", "dubstep", "trap", "lofi", "synthwave",

        // Music Styles / Vibes
        "acoustic", "instrumental", "vocal", "orchestral", "chill", "upbeat",
        "melancholic", "experimental", "progressive", "classic", "retro",

        // Music Activities
        "party", "workout", "mainstream", "underground"
    ]

    /// Number of dimensions in the interest vector
    public static var dimensions: Int { tags.count }

    /// Lookup index for a tag. Returns nil if not in vocabulary.
    public static func index(of tag: String) -> Int? {
        tagIndex[tag]
    }

    /// Extract top N tag names from a raw float vector.
    public static func topTags(from vector: [Float], count: Int = 10) -> [String] {
        guard vector.count == dimensions else { return [] }
        return zip(tags, vector)
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { $0.0 }
    }

    private static let tagIndex: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, tag) in tags.enumerated() {
            map[tag] = i
        }
        return map
    }()
}

// MARK: - Interest Vector

/// A fixed-size vector representing a user's interest profile.
/// Dimensions correspond 1:1 with `InterestVocabulary.tags`.
public struct InterestVector: Codable, Equatable, Sendable {
    public var values: [Float]

    public init() {
        self.values = Array(repeating: 0.0, count: InterestVocabulary.dimensions)
    }

    public init(values: [Float]) {
        precondition(values.count == InterestVocabulary.dimensions,
                     "Vector must have \(InterestVocabulary.dimensions) dimensions, got \(values.count)")
        self.values = values
    }

    /// Build a vector from tag weights using TF-IDF-like scoring
    public init(tagWeights: [String: Float]) {
        var vector = Array(repeating: Float(0), count: InterestVocabulary.dimensions)

        guard !tagWeights.isEmpty else {
            self.values = vector
            return
        }

        let totalWeight = tagWeights.values.reduce(0, +)
        guard totalWeight > 0 else {
            self.values = vector
            return
        }

        let vocabSize = Float(InterestVocabulary.dimensions)

        for (tag, weight) in tagWeights {
            guard let index = InterestVocabulary.index(of: tag) else { continue }
            let tf = weight / totalWeight
            let idf = log(vocabSize / max(1.0, weight))
            vector[index] = tf * idf
        }

        // Normalize to unit length
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            vector = vector.map { $0 / magnitude }
        }

        self.values = vector
    }

    /// Cosine similarity between two vectors. Returns 0 if either is zero.
    public func cosineSimilarity(to other: InterestVector) -> Float {
        guard values.count == other.values.count,
              !values.allSatisfy({ $0 == 0 }),
              !other.values.allSatisfy({ $0 == 0 }) else {
            return 0.0
        }

        let dot = zip(values, other.values).map(*).reduce(0, +)
        let magA = sqrt(values.map { $0 * $0 }.reduce(0, +))
        let magB = sqrt(other.values.map { $0 * $0 }.reduce(0, +))

        return dot / (magA * magB)
    }

    /// Returns the top N tags by weight
    public func topTags(limit: Int = 10) -> [(tag: String, weight: Float)] {
        zip(InterestVocabulary.tags, values)
            .map { (tag: $0, weight: $1) }
            .filter { $0.weight > 0 }
            .sorted { $0.weight > $1.weight }
            .prefix(limit)
            .map { $0 }
    }

    subscript(tag: String) -> Float {
        get {
            guard let index = InterestVocabulary.index(of: tag) else { return 0 }
            return values[index]
        }
        set {
            guard let index = InterestVocabulary.index(of: tag) else { return }
            values[index] = newValue
        }
    }
}
