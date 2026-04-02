import Foundation

// MARK: - Music Genre Mapper

/// Maps Spotify and Apple Music genres to canonical interest tags for the interest vector system.
/// Uses tokenization instead of exhaustive genre enumeration — splits genre strings into words
/// and matches them against the interest vector vocabulary directly. A small synonym map handles
/// non-obvious translations (e.g. "edm" → "electronic", "r&b" → "r_and_b").
struct MusicGenreMapper {

    // MARK: - Vocabulary (must stay in sync with InterestVectorManager.vocabulary)

    /// The set of music-related tags recognized by the interest vector system.
    /// Tokens extracted from genre strings are matched against this set.
    private static let vocabularySet: Set<String> = [
        // Core
        "music", "live_music", "concerts",
        // Genres
        "rock", "pop", "hip_hop", "rap", "electronic", "dance", "jazz", "blues",
        "classical", "country", "folk", "metal", "r_and_b", "soul", "funk",
        "reggae", "latin", "world", "indie", "alternative", "punk", "ambient",
        // Sub-genres
        "house", "techno", "trance", "dubstep", "trap", "lofi", "synthwave",
        // Styles / Vibes
        "acoustic", "instrumental", "vocal", "orchestral", "chill", "upbeat",
        "melancholic", "experimental", "progressive", "classic", "retro",
        // Activities / Context
        "party", "workout", "mainstream", "underground",
        "relaxing", "energetic", "romantic"
    ]

    /// Two-word phrases that map to a single underscore-joined vocabulary tag.
    /// Checked before single-token matching so "hip hop" → "hip_hop" takes priority.
    private static let compoundPhrases: [String: String] = [
        "hip hop": "hip_hop",
        "r and b": "r_and_b",
        "live music": "live_music"
    ]

    /// Single-token synonyms for words that don't appear directly in the vocabulary.
    private static let synonyms: [String: String] = [
        // Genre aliases
        "edm": "electronic",
        "rnb": "r_and_b",
        "dnb": "electronic",
        "electro": "electronic",
        "electronica": "electronic",
        "disco": "dance",
        "dancehall": "dance",
        "grunge": "rock",
        "emo": "rock",
        "ska": "punk",
        "hardcore": "punk",
        "metalcore": "metal",
        "deathcore": "metal",
        "downtempo": "chill",
        "chillwave": "chill",
        "chillout": "chill",
        "shoegaze": "alternative",
        "dreampop": "alternative",
        "postpunk": "punk",
        "postrock": "rock",
        "triphop": "electronic",
        "breakbeat": "electronic",
        "grime": "rap",
        "drill": "rap",
        "afrobeat": "world",
        "afrobeats": "world",
        "afropop": "world",
        "kpop": "pop",
        "jpop": "pop",
        "cpop": "pop",
        "mpb": "latin",
        "salsa": "latin",
        "bachata": "latin",
        "reggaeton": "latin",
        "flamenco": "latin",
        "bossa": "latin",
        "samba": "latin",
        "cumbia": "latin",
        "celtic": "folk",
        "bluegrass": "country",
        "americana": "country",
        "neoclassical": "classical",
        "baroque": "classical",
        "opera": "classical",
        "orchestral": "orchestral",
        "piano": "classical",
        "lofi": "lofi",
        "vaporwave": "electronic",
        "synthpop": "pop",
        "hyperpop": "pop",
        "soundtrack": "instrumental",
        "cinematic": "instrumental",
        "score": "instrumental",
        "meditation": "relaxing",
        "sleep": "relaxing",
        "focus": "chill",
        "study": "chill",
        "happy": "upbeat",
        "sad": "melancholic",
        "angry": "energetic",
        "uplifting": "upbeat",
        "running": "workout",
        "fitness": "workout",
        "oldies": "classic",
        "vintage": "retro"
    ]

    // MARK: - Public Methods

    /// Maps a genre string to canonical interest tags by tokenizing and matching
    /// against the vocabulary. Always includes "music" as a base tag.
    static func mapGenreToTags(_ genre: String) -> [String] {
        let normalized = normalizeGenre(genre)
        var tags: Set<String> = ["music"]

        // Check compound phrases first (e.g. "hip hop" → "hip_hop")
        for (phrase, tag) in compoundPhrases {
            if normalized.contains(phrase) {
                tags.insert(tag)
            }
        }

        // Tokenize and match each word
        let tokens = normalized.split(separator: " ").map(String.init)

        for token in tokens {
            // Direct vocabulary match
            if vocabularySet.contains(token) {
                tags.insert(token)
            }
            // Synonym match
            else if let mapped = synonyms[token] {
                tags.insert(mapped)
            }
        }

        // If we only have "music" (no real matches), try the whole normalized
        // string as a single token against synonyms
        if tags.count == 1 {
            let joined = normalized.replacingOccurrences(of: " ", with: "")
            if let mapped = synonyms[joined] {
                tags.insert(mapped)
            }
        }

        return Array(tags)
    }

    /// Generates an artist tag in canonical format
    static func generateArtistTag(_ artistName: String) -> String {
        let normalized = artistName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }

        return "artist:\(normalized)"
    }

    /// Maps multiple genres and returns aggregated tags with counts
    static func mapGenresToTagCounts(_ genres: [String], baseWeight: Int = 1) -> [String: Int] {
        var tagCounts: [String: Int] = [:]

        for genre in genres {
            let tags = mapGenreToTags(genre)
            for tag in tags {
                tagCounts[tag, default: 0] += baseWeight
            }
        }

        return tagCounts
    }

    // MARK: - Private Methods

    /// Normalizes a genre string for tokenization
    private static func normalizeGenre(_ genre: String) -> String {
        genre
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
    }
}
