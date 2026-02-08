import Foundation
import CoreLocation
import SwiftUI

// MARK: - Interest Vector Computation System

@MainActor
class InterestVectorManager: ObservableObject {
    @Published var currentVector: [Float] = []
    @Published var lastUpdated: Date?
    @Published var vectorQuality: VectorQuality = .poor
    
    private let appleMapsManager: AppleMapsIntegrationManager
    private let photosManager: PhotosIntegrationManager
    private let favoritesManager: InAppFavoritesManager
    private let spotifyManager: SpotifyIntegrationManager?
    private let appleMusicManager: AppleMusicIntegrationManager?
    private let ageRangeManager: AgeRangeManager?

    // Canonical vocabulary for interest tags (expanded with music genres)
    private let vocabulary = [
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
    
    enum VectorQuality {
        case poor      // 0-25% data coverage
        case fair      // 25-50% data coverage
        case good      // 50-75% data coverage
        case excellent // 75%+ data coverage
        
        var description: String {
            switch self {
            case .poor: return "Limited data"
            case .fair: return "Some data"
            case .good: return "Good data"
            case .excellent: return "Rich data"
            }
        }
        
        var color: String {
            switch self {
            case .poor: return "red"
            case .fair: return "orange"
            case .good: return "blue"
            case .excellent: return "green"
            }
        }
    }
    
    init(
        appleMapsManager: AppleMapsIntegrationManager,
        photosManager: PhotosIntegrationManager,
        favoritesManager: InAppFavoritesManager,
        spotifyManager: SpotifyIntegrationManager? = nil,
        appleMusicManager: AppleMusicIntegrationManager? = nil,
        ageRangeManager: AgeRangeManager? = nil
    ) {
        self.appleMapsManager = appleMapsManager
        self.photosManager = photosManager
        self.favoritesManager = favoritesManager
        self.spotifyManager = spotifyManager
        self.appleMusicManager = appleMusicManager
        self.ageRangeManager = ageRangeManager

        loadCachedVector()
        computeVector()
    }
    
    func computeVector() {
        let allTags = aggregateTagsFromAllSources()
        currentVector = vectorFromTags(allTags)
        vectorQuality = assessVectorQuality(allTags)
        lastUpdated = Date()
        
        saveVector()
    }
    
    private func aggregateTagsFromAllSources() -> [String: Float] {
        var aggregatedTags: [String: Float] = [:]

        // Weight different sources based on reliability and user intent
        let sourceWeights: [String: Float] = [
            "favorites": 1.0,     // Highest weight - explicit user preferences
            "spotify": 0.9,       // High weight - explicit music preferences
            "apple_music": 0.9,   // High weight - explicit music preferences
            "apple_maps": 0.8,    // High weight - user's saved places
            "photos": 0.6         // Medium weight - inferred from behavior
        ]

        // Aggregate from in-app favorites (highest priority)
        let favoritesTags = favoritesManager.getInterestTags()
        for (tag, count) in favoritesTags {
            let normalizedTag = normalizeTag(tag)
            if vocabulary.contains(normalizedTag) {
                aggregatedTags[normalizedTag, default: 0] += Float(count) * sourceWeights["favorites"]!
            }
        }

        // Aggregate from Spotify (if connected)
        if let spotifyManager = spotifyManager {
            let spotifyTags = spotifyManager.getInterestTags()
            for (tag, count) in spotifyTags {
                let normalizedTag = normalizeTag(tag)
                if vocabulary.contains(normalizedTag) {
                    aggregatedTags[normalizedTag, default: 0] += Float(count) * sourceWeights["spotify"]!
                }
            }
        }

        // Aggregate from Apple Music (if connected)
        if let appleMusicManager = appleMusicManager {
            let appleMusicTags = appleMusicManager.getInterestTags()
            for (tag, count) in appleMusicTags {
                let normalizedTag = normalizeTag(tag)
                if vocabulary.contains(normalizedTag) {
                    aggregatedTags[normalizedTag, default: 0] += Float(count) * sourceWeights["apple_music"]!
                }
            }
        }

        // Aggregate from Apple Maps saved locations
        let appleMapsTagCounts = appleMapsManager.getInterestTags()
        for (tag, count) in appleMapsTagCounts {
            let normalizedTag = normalizeTag(tag)
            if vocabulary.contains(normalizedTag) {
                aggregatedTags[normalizedTag, default: 0] += Float(count) * sourceWeights["apple_maps"]!
            }
        }

        // Aggregate from Photos analysis
        let photosTagCounts = photosManager.getInterestTags()
        for (tag, count) in photosTagCounts {
            let normalizedTag = normalizeTag(tag)
            if vocabulary.contains(normalizedTag) {
                aggregatedTags[normalizedTag, default: 0] += Float(count) * sourceWeights["photos"]!
            }
        }

        // Aggregate from Age Range (if set) - high weight for filtering
        if let ageRangeManager = ageRangeManager, ageRangeManager.isAuthorized {
            let ageRangeTags = ageRangeManager.getInterestTags()
            for (tag, count) in ageRangeTags {
                let normalizedTag = normalizeTag(tag)
                if vocabulary.contains(normalizedTag) {
                    // Age range tags can be negative (to deprioritize adult venues for minors)
                    aggregatedTags[normalizedTag, default: 0] += Float(count)
                }
            }
        }

        return aggregatedTags
    }
    
    private func vectorFromTags(_ tagCounts: [String: Float]) -> [Float] {
        guard !tagCounts.isEmpty else {
            return Array(repeating: 0.0, count: vocabulary.count)
        }
        
        // Create vector with TF-IDF-like scoring
        var vector: [Float] = Array(repeating: 0.0, count: vocabulary.count)
        let totalTags = tagCounts.values.reduce(0, +)
        
        for (index, tag) in vocabulary.enumerated() {
            if let count = tagCounts[tag] {
                // Term frequency (normalized)
                let tf = count / totalTags
                
                // Inverse document frequency simulation
                // For now, we'll use a simple frequency-based approach
                // In a full implementation, this would use actual corpus statistics
                let idf = logf(Float(vocabulary.count) / max(1.0, count))
                
                vector[index] = tf * idf
            }
        }
        
        // Normalize vector to unit length
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            vector = vector.map { $0 / magnitude }
        }
        
        return vector
    }
    
    private func normalizeTag(_ tag: String) -> String {
        let lowercased = tag.lowercased()
        
        // Simple tag normalization - map synonyms to canonical forms
        let synonymMap: [String: String] = [
            "restaurants": "dining",
            "cafes": "cafe",
            "coffee_shops": "coffee",
            "shops": "shopping",
            "stores": "shopping",
            "parks": "park",
            "outdoors": "outdoor",
            "exercising": "fitness",
            "working_out": "fitness",
            "movies": "entertainment",
            "films": "entertainment",
            "art": "arts",
            "cheap": "budget",
            "expensive": "upscale",
            "pricey": "upscale"
        ]
        
        return synonymMap[lowercased] ?? lowercased
    }
    
    private func assessVectorQuality(_ tagCounts: [String: Float]) -> VectorQuality {
        let totalDataSources: Float = 5.0 // favorites, spotify, apple_music, apple_maps, photos
        var activeDataSources: Float = 0.0

        if !favoritesManager.favorites.isEmpty { activeDataSources += 1.0 }
        if let spotifyManager = spotifyManager, !spotifyManager.topArtists.isEmpty { activeDataSources += 1.0 }
        if let appleMusicManager = appleMusicManager, !appleMusicManager.recentlyPlayed.isEmpty { activeDataSources += 1.0 }
        if !appleMapsManager.savedLocations.isEmpty { activeDataSources += 1.0 }
        if !photosManager.clusters.isEmpty { activeDataSources += 1.0 }

        let dataSourceCoverage = activeDataSources / totalDataSources
        let tagCoverage = Float(tagCounts.count) / Float(vocabulary.count)
        let totalCoverage = (dataSourceCoverage + tagCoverage) / 2.0

        switch totalCoverage {
        case 0.75...: return .excellent
        case 0.5..<0.75: return .good
        case 0.25..<0.5: return .fair
        default: return .poor
        }
    }
    
    func similarityTo(otherVector: [Float]) -> Float {
        guard currentVector.count == otherVector.count,
              !currentVector.allSatisfy({ $0 == 0 }),
              !otherVector.allSatisfy({ $0 == 0 }) else {
            return 0.0
        }
        
        // Cosine similarity
        let dotProduct = zip(currentVector, otherVector).map(*).reduce(0, +)
        let magnitudeA = sqrt(currentVector.map { $0 * $0 }.reduce(0, +))
        let magnitudeB = sqrt(otherVector.map { $0 * $0 }.reduce(0, +))
        
        return dotProduct / (magnitudeA * magnitudeB)
    }
    
    func getTopInterests(limit: Int = 10) -> [(tag: String, weight: Float)] {
        let tagWeights = zip(vocabulary, currentVector).map { (tag: $0, weight: $1) }
        return tagWeights
            .filter { $0.weight > 0 }
            .sorted { $0.weight > $1.weight }
            .prefix(limit)
            .map { $0 }
    }
    
    func getInterestInsights() -> InterestInsights {
        let topInterests = getTopInterests(limit: 5)
        let dominantCategories = getDominantCategories()
        let diversityScore = calculateDiversityScore()
        
        return InterestInsights(
            topInterests: topInterests.map { $0.tag },
            dominantCategories: dominantCategories,
            diversityScore: diversityScore,
            vectorQuality: vectorQuality,
            dataSourcesActive: getActiveDataSources()
        )
    }
    
    private func getDominantCategories() -> [PlaceCategory] {
        // Map vector weights back to place categories
        var categoryWeights: [PlaceCategory: Float] = [:]
        
        for category in PlaceCategory.allCases {
            var weight: Float = 0.0
            for tag in category.interestTags {
                if let index = vocabulary.firstIndex(of: tag) {
                    weight += currentVector[index]
                }
            }
            categoryWeights[category] = weight
        }
        
        return categoryWeights
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }
    }
    
    private func calculateDiversityScore() -> Float {
        // Shannon entropy as a measure of interest diversity
        let nonZeroWeights = currentVector.filter { $0 > 0 }
        guard !nonZeroWeights.isEmpty else { return 0.0 }
        
        let entropy = nonZeroWeights.map { weight in
            weight * logf(weight)
        }.reduce(0, +) * -1
        
        // Normalize to 0-1 scale
        let maxEntropy = logf(Float(nonZeroWeights.count))
        return maxEntropy > 0 ? entropy / maxEntropy : 0.0
    }
    
    private func getActiveDataSources() -> [String] {
        var sources: [String] = []

        if !favoritesManager.favorites.isEmpty {
            sources.append("In-app favorites")
        }
        if let spotifyManager = spotifyManager, !spotifyManager.topArtists.isEmpty {
            sources.append("Spotify")
        }
        if let appleMusicManager = appleMusicManager, !appleMusicManager.recentlyPlayed.isEmpty {
            sources.append("Apple Music")
        }
        if !appleMapsManager.savedLocations.isEmpty {
            sources.append("Saved places")
        }
        if !photosManager.clusters.isEmpty {
            sources.append("Photos analysis")
        }

        return sources
    }
    
    // MARK: - Persistence
    
    private func saveVector() {
        let userDefaults = UserDefaults.standard
        let vectorData = try? JSONEncoder().encode(currentVector)
        userDefaults.set(vectorData, forKey: "interest_vector")
        userDefaults.set(lastUpdated, forKey: "interest_vector_updated")
    }
    
    private func loadCachedVector() {
        let userDefaults = UserDefaults.standard
        
        if let vectorData = userDefaults.data(forKey: "interest_vector"),
           let vector = try? JSONDecoder().decode([Float].self, from: vectorData) {
            currentVector = vector
        }
        
        lastUpdated = userDefaults.object(forKey: "interest_vector_updated") as? Date
    }
}

// MARK: - Interest Insights

struct InterestInsights {
    let topInterests: [String]
    let dominantCategories: [PlaceCategory]
    let diversityScore: Float
    let vectorQuality: InterestVectorManager.VectorQuality
    let dataSourcesActive: [String]
    
    var diversityDescription: String {
        switch diversityScore {
        case 0.8...: return "Very diverse interests"
        case 0.6..<0.8: return "Diverse interests"
        case 0.4..<0.6: return "Focused interests"
        case 0.2..<0.4: return "Narrow interests"
        default: return "Very focused interests"
        }
    }
}

// MARK: - Interest Vector Display View

struct InterestVectorView: View {
    @ObservedObject var vectorManager: InterestVectorManager
    @State private var showingDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Interest Profile")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    vectorManager.computeVector()
                    HapticFeedbackManager.shared.selection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            // Quality indicator
            HStack {
                Circle()
                    .fill(colorForQuality(vectorManager.vectorQuality))
                    .frame(width: 8, height: 8)
                
                Text(vectorManager.vectorQuality.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if let lastUpdated = vectorManager.lastUpdated {
                    Text("• Updated \(lastUpdated, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Top interests preview
            let insights = vectorManager.getInterestInsights()
            if !insights.topInterests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top interests")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(insights.topInterests.prefix(5), id: \.self) { interest in
                                Text(interest.capitalized)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }
            }
            
            // Show details button
            Button {
                showingDetails = true
            } label: {
                Text("View detailed profile")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showingDetails) {
            InterestInsightsDetailView(vectorManager: vectorManager)
        }
    }
    
    private func colorForQuality(_ quality: InterestVectorManager.VectorQuality) -> Color {
        switch quality {
        case .poor: return .red
        case .fair: return .orange
        case .good: return .blue
        case .excellent: return .green
        }
    }
}

// MARK: - Detailed Interest Insights View

struct InterestInsightsDetailView: View {
    @ObservedObject var vectorManager: InterestVectorManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                let insights = vectorManager.getInterestInsights()
                
                VStack(alignment: .leading, spacing: 24) {
                    // Overview section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Profile Overview")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Quality")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(insights.vectorQuality.description)
                                    .font(.headline)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing) {
                                Text("Diversity")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(insights.diversityDescription)
                                    .font(.headline)
                            }
                        }
                        .padding()
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Data sources
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Data Sources")
                            .font(.headline)
                        
                        ForEach(insights.dataSourcesActive, id: \.self) { source in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(source)
                                    .font(.subheadline)
                                Spacer()
                            }
                        }
                        
                        if insights.dataSourcesActive.count < 3 {
                            Text("Connect more data sources to improve your recommendations")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    
                    // Top interests
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Interest Breakdown")
                            .font(.headline)
                        
                        ForEach(Array(vectorManager.getTopInterests(limit: 10).enumerated()), id: \.offset) { index, interest in
                            HStack {
                                Text("\(index + 1).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, alignment: .leading)
                                
                                Text(interest.tag.capitalized)
                                    .font(.subheadline)
                                
                                Spacer()
                                
                                // Weight visualization
                                GeometryReader { geometry in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(.blue)
                                        .frame(width: geometry.size.width * CGFloat(interest.weight * 10))
                                }
                                .frame(width: 60, height: 4)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    
                    // Dominant categories
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Favorite Categories")
                            .font(.headline)
                        
                        ForEach(insights.dominantCategories, id: \.self) { category in
                            HStack {
                                Image(systemName: category.iconName)
                                    .foregroundStyle(.secondary)
                                Text(category.displayName)
                                    .font(.subheadline)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Interest Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    InterestVectorView(vectorManager: InterestVectorManager(
        appleMapsManager: AppleMapsIntegrationManager(),
        photosManager: PhotosIntegrationManager(),
        favoritesManager: InAppFavoritesManager(),
        spotifyManager: SpotifyIntegrationManager(),
        appleMusicManager: AppleMusicIntegrationManager()
    ))
}
