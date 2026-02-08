import Foundation

// MARK: - Music Genre Mapper

/// Maps Spotify and Apple Music genres to canonical interest tags for the interest vector system
struct MusicGenreMapper {

    // MARK: - Genre to Tag Mapping

    /// Comprehensive mapping from music genres to canonical interest tags
    static let genreToTagMapping: [String: [String]] = [
        // Rock & Alternative
        "rock": ["rock", "music", "live_music"],
        "alternative": ["alternative", "indie", "music"],
        "indie": ["indie", "alternative", "music"],
        "indie rock": ["indie", "rock", "alternative"],
        "punk": ["punk", "rock", "energetic"],
        "punk rock": ["punk", "rock", "live_music"],
        "grunge": ["grunge", "rock", "alternative"],
        "hard rock": ["rock", "energetic", "live_music"],
        "classic rock": ["rock", "classic", "music"],
        "soft rock": ["rock", "chill", "music"],
        "progressive rock": ["rock", "progressive", "music"],
        "psychedelic rock": ["rock", "psychedelic", "alternative"],
        "garage rock": ["rock", "indie", "energetic"],
        "post-punk": ["punk", "alternative", "music"],
        "new wave": ["alternative", "synth", "music"],

        // Pop
        "pop": ["pop", "music", "mainstream"],
        "synth-pop": ["pop", "electronic", "synth"],
        "synthpop": ["pop", "electronic", "synth"],
        "indie pop": ["indie", "pop", "alternative"],
        "dance pop": ["pop", "dance", "party"],
        "electropop": ["pop", "electronic", "dance"],
        "k-pop": ["pop", "kpop", "international"],
        "j-pop": ["pop", "jpop", "international"],
        "art pop": ["pop", "art", "alternative"],
        "chamber pop": ["pop", "orchestral", "sophisticated"],
        "dream pop": ["pop", "dreamy", "chill"],
        "bedroom pop": ["pop", "indie", "chill"],
        "hyperpop": ["pop", "electronic", "experimental"],

        // Electronic / Dance
        "electronic": ["electronic", "music", "dance"],
        "edm": ["electronic", "dance", "party"],
        "house": ["electronic", "house", "dance"],
        "deep house": ["electronic", "house", "chill"],
        "tech house": ["electronic", "house", "dance"],
        "progressive house": ["electronic", "house", "progressive"],
        "techno": ["electronic", "techno", "dance"],
        "trance": ["electronic", "trance", "dance"],
        "dubstep": ["electronic", "dubstep", "bass"],
        "drum and bass": ["electronic", "dnb", "energetic"],
        "dnb": ["electronic", "dnb", "energetic"],
        "ambient": ["ambient", "electronic", "chill"],
        "chillwave": ["chill", "electronic", "ambient"],
        "downtempo": ["electronic", "chill", "ambient"],
        "lo-fi": ["lofi", "chill", "ambient"],
        "lofi": ["lofi", "chill", "ambient"],
        "lo-fi beats": ["lofi", "chill", "study"],
        "idm": ["electronic", "experimental", "music"],
        "electro": ["electronic", "dance", "music"],
        "future bass": ["electronic", "bass", "dance"],
        "trap edm": ["electronic", "trap", "bass"],
        "synthwave": ["electronic", "synth", "retro"],
        "vaporwave": ["electronic", "experimental", "retro"],

        // Hip-Hop / R&B
        "hip hop": ["hip_hop", "rap", "music"],
        "hip-hop": ["hip_hop", "rap", "music"],
        "rap": ["hip_hop", "rap", "music"],
        "trap": ["trap", "hip_hop", "music"],
        "conscious hip hop": ["hip_hop", "conscious", "music"],
        "underground hip hop": ["hip_hop", "underground", "indie"],
        "boom bap": ["hip_hop", "classic", "music"],
        "southern hip hop": ["hip_hop", "southern", "music"],
        "west coast hip hop": ["hip_hop", "west_coast", "music"],
        "east coast hip hop": ["hip_hop", "east_coast", "music"],
        "r&b": ["r_and_b", "soul", "music"],
        "rnb": ["r_and_b", "soul", "music"],
        "contemporary r&b": ["r_and_b", "contemporary", "music"],
        "neo soul": ["soul", "neo_soul", "music"],
        "soul": ["soul", "r_and_b", "music"],
        "funk": ["funk", "soul", "groovy"],

        // Jazz / Blues
        "jazz": ["jazz", "music", "sophisticated"],
        "smooth jazz": ["jazz", "chill", "sophisticated"],
        "bebop": ["jazz", "classic", "sophisticated"],
        "free jazz": ["jazz", "experimental", "avantgarde"],
        "jazz fusion": ["jazz", "fusion", "music"],
        "acid jazz": ["jazz", "electronic", "groovy"],
        "blues": ["blues", "music", "soulful"],
        "delta blues": ["blues", "classic", "music"],
        "chicago blues": ["blues", "classic", "music"],
        "blues rock": ["blues", "rock", "music"],

        // Country / Folk / Americana
        "country": ["country", "music", "americana"],
        "folk": ["folk", "acoustic", "music"],
        "indie folk": ["folk", "indie", "acoustic"],
        "americana": ["americana", "country", "folk"],
        "bluegrass": ["bluegrass", "country", "acoustic"],
        "country rock": ["country", "rock", "music"],
        "alt-country": ["country", "alternative", "music"],
        "outlaw country": ["country", "outlaw", "music"],
        "singer-songwriter": ["acoustic", "vocal", "singer_songwriter"],

        // Classical / Orchestral
        "classical": ["classical", "music", "sophisticated"],
        "orchestra": ["classical", "orchestra", "music"],
        "orchestral": ["classical", "orchestra", "music"],
        "piano": ["classical", "piano", "instrumental"],
        "baroque": ["classical", "baroque", "music"],
        "romantic": ["classical", "romantic", "music"],
        "contemporary classical": ["classical", "contemporary", "music"],
        "minimalism": ["classical", "minimal", "ambient"],
        "neoclassical": ["classical", "neoclassical", "music"],
        "opera": ["classical", "opera", "vocal"],

        // Metal
        "metal": ["metal", "rock", "energetic"],
        "heavy metal": ["metal", "rock", "energetic"],
        "death metal": ["metal", "extreme", "music"],
        "black metal": ["metal", "extreme", "music"],
        "thrash metal": ["metal", "thrash", "energetic"],
        "metalcore": ["metal", "core", "energetic"],
        "progressive metal": ["metal", "progressive", "music"],
        "doom metal": ["metal", "doom", "heavy"],
        "nu metal": ["metal", "nu_metal", "music"],
        "power metal": ["metal", "power", "energetic"],

        // World / International
        "latin": ["latin", "international", "music"],
        "latin pop": ["latin", "pop", "music"],
        "reggaeton": ["reggaeton", "latin", "dance"],
        "salsa": ["salsa", "latin", "dance"],
        "bachata": ["bachata", "latin", "music"],
        "reggae": ["reggae", "caribbean", "music"],
        "dub": ["dub", "reggae", "electronic"],
        "dancehall": ["dancehall", "caribbean", "dance"],
        "afrobeat": ["afrobeat", "international", "music"],
        "afropop": ["afropop", "international", "pop"],
        "afrobeats": ["afrobeats", "international", "dance"],
        "bossa nova": ["bossa_nova", "latin", "chill"],
        "mpb": ["mpb", "brazilian", "music"],
        "flamenco": ["flamenco", "spanish", "music"],
        "celtic": ["celtic", "folk", "international"],
        "world": ["world", "international", "music"],
        "world music": ["world", "international", "music"],

        // Other Genres
        "acoustic": ["acoustic", "music", "chill"],
        "instrumental": ["instrumental", "music"],
        "soundtrack": ["soundtrack", "instrumental", "cinematic"],
        "score": ["soundtrack", "orchestral", "cinematic"],
        "video game music": ["gaming", "soundtrack", "electronic"],
        "anime": ["anime", "soundtrack", "japanese"],
        "gospel": ["gospel", "spiritual", "vocal"],
        "christian": ["christian", "spiritual", "music"],
        "worship": ["worship", "spiritual", "music"],
        "meditation": ["meditation", "ambient", "relaxing"],
        "sleep": ["sleep", "ambient", "relaxing"],
        "focus": ["focus", "study", "ambient"],
        "study": ["study", "focus", "chill"],
        "chill": ["chill", "relaxing", "ambient"],
        "party": ["party", "dance", "energetic"],
        "workout": ["workout", "energetic", "fitness"],
        "running": ["running", "workout", "energetic"],

        // Decades / Eras
        "80s": ["retro", "80s", "music"],
        "90s": ["retro", "90s", "music"],
        "2000s": ["2000s", "music"],
        "oldies": ["oldies", "classic", "music"],
        "vintage": ["vintage", "retro", "music"],

        // Moods / Vibes
        "happy": ["happy", "upbeat", "positive"],
        "sad": ["melancholic", "emotional", "introspective"],
        "angry": ["aggressive", "energetic", "intense"],
        "romantic": ["romantic", "love", "emotional"],
        "relaxing": ["relaxing", "chill", "ambient"],
        "energetic": ["energetic", "upbeat", "party"],
        "melancholic": ["melancholic", "emotional", "introspective"],
        "uplifting": ["uplifting", "positive", "inspiring"]
    ]

    // MARK: - Public Methods

    /// Maps a genre string to canonical interest tags
    /// - Parameter genre: The genre string from Spotify or Apple Music
    /// - Returns: Array of canonical interest tags
    static func mapGenreToTags(_ genre: String) -> [String] {
        let normalizedGenre = normalizeGenre(genre)

        // Direct mapping
        if let tags = genreToTagMapping[normalizedGenre] {
            return tags
        }

        // Partial matching for compound genres
        for (key, tags) in genreToTagMapping {
            if normalizedGenre.contains(key) || key.contains(normalizedGenre) {
                return tags
            }
        }

        // Fallback: return the normalized genre itself plus "music"
        let fallbackTag = normalizedGenre.replacingOccurrences(of: " ", with: "_")
        return [fallbackTag, "music"]
    }

    /// Generates an artist tag in canonical format
    /// - Parameter artistName: The artist name
    /// - Returns: Formatted artist tag like "artist:phoebe_bridgers"
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
    /// - Parameters:
    ///   - genres: Array of genre strings
    ///   - baseWeight: Weight to apply to each genre
    /// - Returns: Dictionary of tags to weighted counts
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

    /// Normalizes a genre string for matching
    private static func normalizeGenre(_ genre: String) -> String {
        return genre
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Music Interest Vocabulary Extension

/// Extended vocabulary specifically for music-related interests
/// These tags can be added to the main InterestVectorComputation vocabulary
struct MusicInterestVocabulary {

    static let musicTags: [String] = [
        // Core music tags
        "music", "live_music", "concerts",

        // Genres
        "rock", "pop", "hip_hop", "rap", "electronic", "dance",
        "jazz", "blues", "classical", "country", "folk", "metal",
        "r_and_b", "soul", "funk", "reggae", "latin", "world",
        "indie", "alternative", "punk", "ambient",

        // Sub-genres
        "house", "techno", "trance", "dubstep", "dnb",
        "trap", "lofi", "synthwave", "neo_soul",

        // Styles / Vibes
        "acoustic", "instrumental", "vocal", "orchestral",
        "chill", "energetic", "upbeat", "melancholic",
        "experimental", "progressive", "classic", "retro",

        // Music-related activities
        "dj", "producer", "vinyl", "festival",

        // Mood/Context
        "party", "study", "workout", "relaxing", "focus",
        "romantic", "emotional", "inspiring"
    ]

    /// Returns all music-related tags for vocabulary extension
    static var allTags: [String] {
        return musicTags
    }
}
