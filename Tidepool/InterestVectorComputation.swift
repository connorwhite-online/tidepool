import Foundation
import CoreLocation
import SwiftUI
import TidepoolShared

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

    // Canonical vocabulary shared between client and server (from TidepoolShared)
    private let vocabulary = InterestVocabulary.tags
    
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
        uploadVectorToServer()
    }

    /// Upload multi-vector payload to the backend.
    private func uploadVectorToServer() {
        guard !currentVector.isEmpty else { return }

        let qualityString: String
        switch vectorQuality {
        case .poor: qualityString = "poor"
        case .fair: qualityString = "fair"
        case .good: qualityString = "good"
        case .excellent: qualityString = "excellent"
        }

        // Collect raw music genres (preserving granularity)
        let musicGenres = collectRawMusicGenres()

        // Collect place POI frequencies from visit history + favorites
        let placePois = collectPlacePois()

        let multiRequest = MultiVectorRequest(
            musicGenres: musicGenres,
            placePois: placePois,
            vibeVector: currentVector,
            quality: qualityString,
            activeSources: getActiveDataSources()
        )

        Task {
            do {
                let _ = try await BackendClient.shared.uploadMultiVector(multiRequest)
                print("[InterestVectorManager] Multi-vector uploaded (music: \(musicGenres.count) genres, places: \(placePois.count) POIs, vibe: \(currentVector.count) dims)")
            } catch {
                // Fallback: try legacy single-vector upload
                let legacyRequest = ProfileVectorRequest(
                    vector: currentVector,
                    quality: qualityString,
                    activeSources: getActiveDataSources()
                )
                let _ = try? await BackendClient.shared.uploadVector(legacyRequest)
                print("[InterestVectorManager] Multi-vector failed, legacy fallback: \(error.localizedDescription)")
            }
        }
    }

    /// Collect raw genre strings with weights from Spotify + Apple Music (no mapper flattening).
    private func collectRawMusicGenres() -> [String: Float] {
        var genres: [String: Float] = [:]

        // Spotify: raw artist genres with position weighting
        if let spotify = spotifyManager {
            for (i, artist) in spotify.topArtists.enumerated() {
                let weight = Float(max(1, 10 - i / 5))
                for genre in artist.genres {
                    genres[genre.lowercased(), default: 0] += weight
                }
            }
        }

        // Apple Music: raw genre names from library
        if let appleMusic = appleMusicManager {
            for (genre, count) in appleMusic.libraryGenres {
                genres[genre.lowercased(), default: 0] += Float(min(count, 10))
            }
            // Recently played bonus
            for track in appleMusic.recentlyPlayed {
                for genre in track.genreNames {
                    genres[genre.lowercased(), default: 0] += 2.0
                }
            }
        }

        return genres
    }

    /// Collect POI visit frequencies from VisitDetector + favorites.
    private func collectPlacePois() -> [String: Float] {
        var pois: [String: Float] = [:]

        // From favorites (boolean signal — 1.0 per favorite)
        for fav in favoritesManager.favorites {
            pois[fav.placeId, default: 0] += 1.0
        }

        return pois
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
    
    // MARK: - Per-Source Insights

    struct TagWeight: Identifiable {
        let id = UUID()
        let tag: String
        let weight: Float
    }

    struct SourceInsight {
        let name: String
        let icon: String
        let color: Color
        let topTags: [TagWeight]
        let isConnected: Bool
    }

    func getSourceInsights() -> [SourceInsight] {
        var sources: [SourceInsight] = []

        // Favorites — show actual place names and categories
        let favTags = favoritesRawInsights()
        sources.append(SourceInsight(
            name: "Favorites", icon: "star.fill", color: .yellow,
            topTags: favTags, isConnected: !favoritesManager.favorites.isEmpty
        ))

        // Spotify — show raw genre strings from artists
        if let spotify = spotifyManager {
            let tags = spotifyRawInsights(spotify)
            sources.append(SourceInsight(
                name: "Spotify", icon: "waveform", color: .green,
                topTags: tags, isConnected: !spotify.topArtists.isEmpty
            ))
        }

        // Apple Music — show raw genre names from library
        if let appleMusic = appleMusicManager {
            let tags = appleMusicRawInsights(appleMusic)
            sources.append(SourceInsight(
                name: "Apple Music", icon: "music.note", color: .red,
                topTags: tags, isConnected: !appleMusic.recentlyPlayed.isEmpty
            ))
        }

        // Photos — show inferred place names
        let photoTags = photosRawInsights()
        sources.append(SourceInsight(
            name: "Photos", icon: "photo.fill", color: .orange,
            topTags: photoTags, isConnected: !photosManager.clusters.isEmpty
        ))

        return sources
    }

    /// Favorites: show category breakdown by actual place categories
    private func favoritesRawInsights() -> [TagWeight] {
        var categoryCounts: [String: Int] = [:]
        for fav in favoritesManager.favorites {
            categoryCounts[fav.category.displayName, default: 0] += 1
        }
        return topWeighted(from: categoryCounts)
    }

    /// Spotify: show raw genre strings from top artists (no mapper)
    private func spotifyRawInsights(_ spotify: SpotifyIntegrationManager) -> [TagWeight] {
        var genreCounts: [String: Int] = [:]
        for (i, artist) in spotify.topArtists.enumerated() {
            let weight = max(1, 10 - i / 5)
            for genre in artist.genres {
                genreCounts[genre, default: 0] += weight
            }
        }
        return topWeighted(from: genreCounts)
    }

    /// Apple Music: show raw genre names from library, artists, and recently played
    private func appleMusicRawInsights(_ appleMusic: AppleMusicIntegrationManager) -> [TagWeight] {
        var genreCounts: [String: Int] = [:]
        for (genre, count) in appleMusic.libraryGenres {
            genreCounts[genre, default: 0] += count
        }
        for track in appleMusic.recentlyPlayed {
            for genre in track.genreNames {
                genreCounts[genre, default: 0] += 2
            }
        }
        // Also pull from library artists if genres are sparse
        for artist in appleMusic.libraryArtists {
            for genre in artist.genres {
                genreCounts[genre, default: 0] += 1
            }
        }
        return topWeighted(from: genreCounts)
    }

    /// Photos: show matched place names vs unmatched (by cluster count)
    private func photosRawInsights() -> [TagWeight] {
        let nonHome = photosManager.clusters.filter { $0.category != .home }
        guard !nonHome.isEmpty else { return [] }

        let matched = nonHome.filter { $0.inferredName != nil && !$0.inferredName!.isEmpty && $0.category != .other }
        let unmatchedCount = nonHome.count - matched.count
        let total = Float(nonHome.count)

        // Top 5 matched places sorted by photo count
        var results: [TagWeight] = matched
            .sorted { $0.photoCount > $1.photoCount }
            .prefix(5)
            .enumerated()
            .map { _, cluster in
                TagWeight(tag: cluster.inferredName!, weight: 1.0 / total)
            }

        // Distribute matched portion evenly across shown places
        if !results.isEmpty {
            let matchedShare = Float(matched.count) / total
            let perSlice = matchedShare / Float(results.count)
            results = results.map { TagWeight(tag: $0.tag, weight: perSlice) }
        }

        if unmatchedCount > 0 {
            results.append(TagWeight(
                tag: "\(unmatchedCount) unresolved",
                weight: Float(unmatchedCount) / total
            ))
        }

        return results
    }

    private func topWeighted(from counts: [String: Int], limit: Int = 6) -> [TagWeight] {
        let sorted = counts.sorted { $0.value > $1.value }.prefix(limit)
        let total = Float(sorted.reduce(0) { $0 + $1.value })
        guard total > 0 else { return [] }
        return sorted.map { TagWeight(tag: $0.key, weight: Float($0.value) / total) }
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

    private let tagColors: [Color] = [.pink, .purple, .blue, .cyan, .teal, .green, .orange, .red, .indigo, .mint]

    var body: some View {
        let insights = vectorManager.getInterestInsights()

        VStack(spacing: 16) {
            // Quality ring
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color(UIColor.quaternarySystemFill), lineWidth: 4)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: qualityProgress)
                        .stroke(
                            colorForQuality(vectorManager.vectorQuality).gradient,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                    Text(qualityEmoji)
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(vectorManager.vectorQuality.description + " profile")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text("\(insights.dataSourcesActive.count) source\(insights.dataSourcesActive.count == 1 ? "" : "s") connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    vectorManager.computeVector()
                    HapticFeedbackManager.shared.selection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color(UIColor.quaternarySystemFill))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Interest bubbles
            if !insights.topInterests.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(Array(insights.topInterests.prefix(8).enumerated()), id: \.offset) { i, interest in
                        Text(interest.capitalized.replacingOccurrences(of: "_", with: " "))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(tagColors[i % tagColors.count])
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(tagColors[i % tagColors.count].opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }

            // Explore button
            Button {
                showingDetails = true
            } label: {
                HStack {
                    Text("Explore your full profile")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingDetails) {
            InterestInsightsDetailView(vectorManager: vectorManager)
        }
    }

    private var qualityProgress: CGFloat {
        switch vectorManager.vectorQuality {
        case .poor: return 0.15
        case .fair: return 0.4
        case .good: return 0.7
        case .excellent: return 1.0
        }
    }

    private var qualityEmoji: String {
        switch vectorManager.vectorQuality {
        case .poor: return "🌱"
        case .fair: return "🌿"
        case .good: return "🌳"
        case .excellent: return "✨"
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

/// Simple flow layout that wraps content to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}

// MARK: - Donut Skeleton

struct DonutSkeletonView: View {
    @State private var shimmer = false

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            // Skeleton donut ring
            Circle()
                .stroke(Color(UIColor.quaternarySystemFill), lineWidth: 14)
                .frame(width: 64, height: 64)

            // Skeleton legend rows
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(UIColor.quaternarySystemFill))
                            .frame(width: 8, height: 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(UIColor.quaternarySystemFill))
                            .frame(width: CGFloat([90, 70, 110, 60][i]), height: 10)
                        Spacer()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(UIColor.quaternarySystemFill))
                            .frame(width: 28, height: 10)
                    }
                }
            }
        }
        .opacity(shimmer ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}

// MARK: - Reusable Donut Chart

struct DonutChartView: View {
    let tags: [InterestVectorManager.TagWeight]
    var size: CGFloat = 72
    var lineWidth: CGFloat = 16

    private let colors: [Color] = [.purple, .blue, .cyan, .teal, .green, .orange, .red, .indigo, .mint, .yellow]

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            ZStack {
                ForEach(Array(tags.enumerated()), id: \.offset) { i, tagWeight in
                    let start = tags.prefix(i).reduce(Float(0)) { $0 + $1.weight }
                    let end = start + tagWeight.weight
                    Circle()
                        .trim(from: CGFloat(start), to: CGFloat(end))
                        .stroke(
                            colors[i % colors.count].gradient,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: size, height: size)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(tags.enumerated()), id: \.offset) { i, tagWeight in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colors[i % colors.count])
                            .frame(width: 8, height: 8)
                        Text(tagWeight.tag.capitalized.replacingOccurrences(of: "_", with: " "))
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(tagWeight.weight * 100))%")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
                let sources = vectorManager.getSourceInsights()
                let insights = vectorManager.getInterestInsights()

                VStack(spacing: 20) {
                    // Blended top interests header
                    VStack(spacing: 12) {
                        Text("Your Blended Taste")
                            .font(.title3)
                            .fontWeight(.bold)

                        FlowLayout(spacing: 8) {
                            ForEach(Array(vectorManager.getTopInterests(limit: 8).enumerated()), id: \.offset) { i, interest in
                                let colors: [Color] = [.pink, .purple, .blue, .cyan, .teal, .green, .orange, .indigo]
                                let c = colors[i % colors.count]
                                Text(interest.tag.capitalized.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(c)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(c.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }

                        // Diversity badge
                        Text(insights.diversityDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    // Per-source cards
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        sourceCard(source)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Your Taste Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private let sliceColors: [Color] = [.purple, .blue, .cyan, .teal, .green, .orange, .red, .indigo, .mint, .yellow]

    private func sourceCard(_ source: InterestVectorManager.SourceInsight) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Source header
            HStack(spacing: 10) {
                Image(systemName: source.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(source.color.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: source.color.opacity(0.3), radius: 4, y: 2)

                Text(source.name)
                    .font(.subheadline)
                    .fontWeight(.bold)

                Spacer()

                if source.isConnected {
                    Text("Active")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.12))
                        .clipShape(Capsule())
                } else {
                    Text("Not connected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if source.isConnected && !source.topTags.isEmpty {
                // Donut + legend layout
                HStack(alignment: .center, spacing: 24) {
                    // Donut chart
                    ZStack {
                        ForEach(Array(source.topTags.enumerated()), id: \.offset) { i, tagWeight in
                            let startAngle = sliceStartAngle(for: i, in: source.topTags)
                            let endAngle = sliceEndAngle(for: i, in: source.topTags)
                            Circle()
                                .trim(from: startAngle, to: endAngle)
                                .stroke(
                                    sliceColors[i % sliceColors.count].gradient,
                                    style: StrokeStyle(lineWidth: 16, lineCap: .butt)
                                )
                                .rotationEffect(.degrees(-90))
                        }
                    }
                    .frame(width: 72, height: 72)

                    // Legend
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(source.topTags.enumerated()), id: \.offset) { i, tagWeight in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(sliceColors[i % sliceColors.count])
                                    .frame(width: 8, height: 8)

                                Text(tagWeight.tag.capitalized.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)

                                Spacer()

                                Text("\(Int(tagWeight.weight * 100))%")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if !source.isConnected {
                Text("Connect to discover what this reveals about you")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No signals yet — keep using it!")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: source.color.opacity(0.06), radius: 10, y: 3)
    }

    private func sliceStartAngle(for index: Int, in tags: [InterestVectorManager.TagWeight]) -> CGFloat {
        let preceding = tags.prefix(index).reduce(Float(0)) { $0 + $1.weight }
        return CGFloat(preceding)
    }

    private func sliceEndAngle(for index: Int, in tags: [InterestVectorManager.TagWeight]) -> CGFloat {
        let through = tags.prefix(index + 1).reduce(Float(0)) { $0 + $1.weight }
        return CGFloat(through)
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
