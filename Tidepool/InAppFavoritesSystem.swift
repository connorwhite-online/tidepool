import Foundation
import CoreLocation
import SwiftUI

// MARK: - Favorite Location Data Model

struct FavoriteLocation: Identifiable, Codable {
    let id: UUID
    let placeId: String
    let name: String
    let category: PlaceCategory
    let coordinate: CLLocationCoordinate2D
    let rating: Int // 1-5 scale
    let notes: String?
    let createdAt: Date
    let lastVisited: Date?
    let visitCount: Int
    let tags: [String]
    
    enum CodingKeys: String, CodingKey {
        case id, placeId, name, category, rating, notes, createdAt, lastVisited, visitCount, tags
        case latitude, longitude
    }
    
    init(placeId: String, name: String, category: PlaceCategory, coordinate: CLLocationCoordinate2D, rating: Int, notes: String? = nil, tags: [String] = []) {
        self.id = UUID()
        self.placeId = placeId
        self.name = name
        self.category = category
        self.coordinate = coordinate
        self.rating = rating
        self.notes = notes
        self.createdAt = Date()
        self.lastVisited = nil
        self.visitCount = 1
        self.tags = tags
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        placeId = try container.decode(String.self, forKey: .placeId)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(PlaceCategory.self, forKey: .category)
        rating = try container.decode(Int.self, forKey: .rating)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastVisited = try container.decodeIfPresent(Date.self, forKey: .lastVisited)
        visitCount = try container.decode(Int.self, forKey: .visitCount)
        tags = try container.decode([String].self, forKey: .tags)
        
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(placeId, forKey: .placeId)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encode(rating, forKey: .rating)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastVisited, forKey: .lastVisited)
        try container.encode(visitCount, forKey: .visitCount)
        try container.encode(tags, forKey: .tags)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
    }
    
    /// Get interest weight based on rating, visit count, and recency
    var interestWeight: Double {
        let ratingWeight = Double(rating) / 5.0
        let visitWeight = min(Double(visitCount) / 10.0, 1.0) // Cap at 10 visits
        let recencyWeight = recencyScore()
        
        return (ratingWeight * 0.5) + (visitWeight * 0.3) + (recencyWeight * 0.2)
    }
    
    private func recencyScore() -> Double {
        let daysSinceCreated = Date().timeIntervalSince(createdAt) / (24 * 60 * 60)
        // Decay function: newer favorites have higher weight
        return exp(-daysSinceCreated / 90.0) // 90-day half-life
    }
}

// MARK: - FavoriteLocation Extensions

extension FavoriteLocation: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension FavoriteLocation: Equatable {
    static func == (lhs: FavoriteLocation, rhs: FavoriteLocation) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - In-App Favorites Manager

@MainActor
class InAppFavoritesManager: ObservableObject {
    @Published var favorites: [FavoriteLocation] = []
    @Published var sortOrder: SortOrder = .recentlyAdded
    @Published var filterCategory: PlaceCategory?
    @Published var searchText: String = ""
    
    private let userDefaults = UserDefaults.standard
    private let favoritesKey = "in_app_favorites"
    
    enum SortOrder: String, CaseIterable {
        case recentlyAdded = "Recently Added"
        case highestRated = "Highest Rated"
        case mostVisited = "Most Visited"
        case alphabetical = "A to Z"
        case category = "Category"
        
        func sort(_ favorites: [FavoriteLocation]) -> [FavoriteLocation] {
            switch self {
            case .recentlyAdded:
                return favorites.sorted { $0.createdAt > $1.createdAt }
            case .highestRated:
                return favorites.sorted { $0.rating > $1.rating }
            case .mostVisited:
                return favorites.sorted { $0.visitCount > $1.visitCount }
            case .alphabetical:
                return favorites.sorted { $0.name < $1.name }
            case .category:
                return favorites.sorted { $0.category.displayName < $1.category.displayName }
            }
        }
    }
    
    init() {
        loadFavorites()
    }
    
    var filteredAndSortedFavorites: [FavoriteLocation] {
        var filtered = favorites
        
        // Apply category filter
        if let filterCategory = filterCategory {
            filtered = filtered.filter { $0.category == filterCategory }
        }
        
        // Apply search filter
        if !searchText.isEmpty {
            filtered = filtered.filter { favorite in
                favorite.name.localizedCaseInsensitiveContains(searchText) ||
                favorite.category.displayName.localizedCaseInsensitiveContains(searchText) ||
                favorite.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        
        return sortOrder.sort(filtered)
    }
    
    func addFavorite(placeId: String, name: String, category: PlaceCategory, coordinate: CLLocationCoordinate2D, rating: Int, notes: String? = nil, tags: [String] = []) {
        let favorite = FavoriteLocation(
            placeId: placeId,
            name: name,
            category: category,
            coordinate: coordinate,
            rating: rating,
            notes: notes,
            tags: tags
        )
        
        favorites.append(favorite)
        saveFavorites()
        
        // Haptic feedback for successful addition
        HapticFeedbackManager.shared.notification(.success)
    }
    
    func removeFavorite(for placeId: String) {
        favorites.removeAll { $0.placeId == placeId }
        saveFavorites()
        
        // Haptic feedback for removal
        HapticFeedbackManager.shared.impact(.medium)
    }
    
    func updateFavorite(_ favorite: FavoriteLocation, rating: Int? = nil, notes: String? = nil, tags: [String]? = nil) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        
        let updatedFavorite = FavoriteLocation(
            placeId: favorite.placeId,
            name: favorite.name,
            category: favorite.category,
            coordinate: favorite.coordinate,
            rating: rating ?? favorite.rating,
            notes: notes ?? favorite.notes,
            tags: tags ?? favorite.tags
        )
        
        favorites[index] = updatedFavorite
        saveFavorites()
    }
    
    func recordVisit(for placeId: String) {
        guard let index = favorites.firstIndex(where: { $0.placeId == placeId }) else { return }
        
        let favorite = favorites[index]
        let updatedFavorite = FavoriteLocation(
            placeId: favorite.placeId,
            name: favorite.name,
            category: favorite.category,
            coordinate: favorite.coordinate,
            rating: favorite.rating,
            notes: favorite.notes,
            tags: favorite.tags
        )
        
        // This would be a more complex update in a real implementation
        // For now, just increment visit count conceptually
        favorites[index] = updatedFavorite
        saveFavorites()
    }
    
    func isFavorited(_ placeId: String) -> Bool {
        return favorites.contains { $0.placeId == placeId }
    }
    
    func getFavorite(for placeId: String) -> FavoriteLocation? {
        return favorites.first { $0.placeId == placeId }
    }
    
    /// Get interest tags for recommendation system
    func getInterestTags() -> [String: Int] {
        var tagCounts: [String: Int] = [:]
        
        for favorite in favorites {
            let weight = max(1, Int(favorite.interestWeight * 10))
            
            // Add category tags
            for tag in favorite.category.interestTags {
                tagCounts[tag, default: 0] += weight
            }
            
            // Add user-defined tags
            for tag in favorite.tags {
                tagCounts[tag.lowercased(), default: 0] += weight
            }
            
            // Add rating-based tags
            if favorite.rating >= 4 {
                tagCounts["highly_rated", default: 0] += weight
            }
        }
        
        return tagCounts
    }
    
    /// Get stats for profile display
    func getStats() -> FavoriteStats {
        let totalFavorites = favorites.count
        let averageRating = favorites.isEmpty ? 0.0 : Double(favorites.map { $0.rating }.reduce(0, +)) / Double(favorites.count)
        let categoryCounts = Dictionary(grouping: favorites, by: { $0.category })
            .mapValues { $0.count }
        let topCategory = categoryCounts.max(by: { $0.value < $1.value })?.key
        
        return FavoriteStats(
            totalFavorites: totalFavorites,
            averageRating: averageRating,
            topCategory: topCategory,
            categoryCounts: categoryCounts
        )
    }
    
    private func loadFavorites() {
        guard let data = userDefaults.data(forKey: favoritesKey),
              let loadedFavorites = try? JSONDecoder().decode([FavoriteLocation].self, from: data) else {
            return
        }
        favorites = loadedFavorites
    }
    
    private func saveFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        userDefaults.set(data, forKey: favoritesKey)
    }
}

struct FavoriteStats {
    let totalFavorites: Int
    let averageRating: Double
    let topCategory: PlaceCategory?
    let categoryCounts: [PlaceCategory: Int]
}

// MARK: - Favorites List View

struct FavoritesListView: View {
    @ObservedObject var favoritesManager: InAppFavoritesManager
    @State private var showingSortOptions = false
    @State private var selectedFavorite: FavoriteLocation?
    @State private var showingLocationDetail = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search and filter header
                headerSection
                
                // Favorites list
                if favoritesManager.filteredAndSortedFavorites.isEmpty {
                    emptyStateView
                } else {
                    favoritesList
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSortOptions = true
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .confirmationDialog("Sort by", isPresented: $showingSortOptions) {
                ForEach(InAppFavoritesManager.SortOrder.allCases, id: \.self) { order in
                    Button(order.rawValue) {
                        withAnimation(SpringPhysics.standard.swiftUISpring) {
                            favoritesManager.sortOrder = order
                        }
                    }
                }
            }
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("Search favorites...", text: $favoritesManager.searchText)
                    .textFieldStyle(.plain)
                
                if !favoritesManager.searchText.isEmpty {
                    Button("Clear") {
                        favoritesManager.searchText = ""
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            // Category filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("All") {
                        withAnimation(SpringPhysics.standard.swiftUISpring) {
                            favoritesManager.filterCategory = nil
                        }
                    }
                    .buttonStyle(FilterButtonStyle(isSelected: favoritesManager.filterCategory == nil))
                    
                    ForEach(uniqueCategories, id: \.self) { category in
                        Button(category.displayName) {
                            withAnimation(SpringPhysics.standard.swiftUISpring) {
                                favoritesManager.filterCategory = category
                            }
                        }
                        .buttonStyle(FilterButtonStyle(isSelected: favoritesManager.filterCategory == category))
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    
    private var uniqueCategories: [PlaceCategory] {
        Array(Set(favoritesManager.favorites.map { $0.category })).sorted { $0.displayName < $1.displayName }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.circle")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            Text("No favorites yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Start exploring and add places you love to see them here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var favoritesList: some View {
        List {
            ForEach(favoritesManager.filteredAndSortedFavorites.indices, id: \.self) { index in
                let favorite = favoritesManager.filteredAndSortedFavorites[index]
                FavoriteRowView(favorite: favorite, favoritesManager: favoritesManager)
                    .staggeredAnimation(delay: Double(index) * 0.05)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            withAnimation(SpringPhysics.standard.swiftUISpring) {
                                favoritesManager.removeFavorite(for: favorite.placeId)
                            }
                        }
                    }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Favorite Row View

struct FavoriteRowView: View {
    let favorite: FavoriteLocation
    @ObservedObject var favoritesManager: InAppFavoritesManager
    @State private var isPressed = false
    
    var body: some View {
        Button {
            // Handle tap to show location detail
            HapticFeedbackManager.shared.selection()
        } label: {
            HStack(spacing: 12) {
                // Category icon
                Image(systemName: favorite.category.iconName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(favorite.name)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    HStack(spacing: 8) {
                        // Rating stars
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: star <= favorite.rating ? "star.fill" : "star")
                                    .font(.caption)
                                    .foregroundStyle(star <= favorite.rating ? .yellow : .secondary)
                            }
                        }
                        
                        Text(favorite.category.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Text(favorite.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let notes = favorite.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                
                // Favorite heart
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .satisfyingSpring(isActive: isPressed)
                    .onTapGesture {
                        withAnimation(SpringPhysics.snappy.swiftUISpring) {
                            isPressed = true
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(SpringPhysics.snappy.swiftUISpring) {
                                isPressed = false
                            }
                        }
                        
                        HapticFeedbackManager.shared.impact(.light)
                    }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter Button Style

struct FilterButtonStyle: ButtonStyle {
    let isSelected: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color(UIColor.quaternarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isSelected ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(SpringPhysics.snappy.swiftUISpring, value: configuration.isPressed)
    }
}

#Preview {
    FavoritesListView(favoritesManager: {
        let manager = InAppFavoritesManager()
        // Add sample data
        manager.addFavorite(
            placeId: "1",
            name: "Blue Bottle Coffee",
            category: .cafe,
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            rating: 5,
            notes: "Great coffee and atmosphere",
            tags: ["coffee", "work"]
        )
        return manager
    }())
}
