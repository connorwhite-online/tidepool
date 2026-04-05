//
//  ContentView.swift
//  Tidepool
//
//  Created by Connor White on 8/7/25.
//

import SwiftUI
import MapKit
import UIKit
import TidepoolShared

struct ContentView: View {
    @AppStorage("has_onboarded") private var hasOnboarded: Bool = false
    @EnvironmentObject var favoritesManager: InAppFavoritesManager
    @State private var showOnboarding: Bool = false
    @State private var navigationPath = NavigationPath()
    @State private var selectedLocationDetail: LocationDetail?
    @State private var mapCenterCoordinate = CLLocationCoordinate2D(latitude: 34.096, longitude: -118.273)
    @State private var navigateToCoordinate: CLLocationCoordinate2D?
    @State private var searchResultPin: POIAnnotation?

    // Search
    @State private var showingSearchSheet = false
    @State private var isBarExpanding = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottom) {
                // Map
                MapHomeView(
                    selectedLocationDetail: $selectedLocationDetail,
                    mapCenterCoordinate: $mapCenterCoordinate,
                    navigateToCoordinate: $navigateToCoordinate,
                    searchResultPin: $searchResultPin
                )
                .ignoresSafeArea()

                // Floating bottom bar
                if selectedLocationDetail == nil {
                    floatingBottomBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // POI detail modal
                LocationDetailModal(
                    selectedLocation: $selectedLocationDetail,
                    favoritesManager: favoritesManager
                )
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedLocationDetail == nil)
            .navigationBarHidden(true)
            .navigationDestination(for: String.self) { destination in
                if destination == "layers" {
                    ProfileView()
                        .navigationBarBackButtonHidden(true)
                }
            }
            .sheet(isPresented: $showingSearchSheet, onDismiss: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isBarExpanding = false
                }
            }) {
                MapSearchSheet(
                    mapCenter: mapCenterCoordinate,
                    favoritesManager: favoritesManager,
                    onSelectResult: { mapItem in
                        showingSearchSheet = false
                        navigateToResult(mapItem)
                    },
                    onSelectFavorite: { favorite in
                        showingSearchSheet = false
                        navigateToFavorite(favorite)
                    }
                )
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
                .presentationCornerRadius(32)
            }
        }
        .fontDesign(.rounded)
        .onAppear { showOnboarding = !hasOnboarded }
        .onChange(of: hasOnboarded) { _, newValue in
            showOnboarding = !newValue
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .onChange(of: selectedLocationDetail?.id) { oldVal, newVal in
            if oldVal != nil && newVal == nil {
                searchResultPin = nil
            }
        }
    }

    // MARK: - Floating Bottom Bar

    private func triggerSearchSheet() {
        HapticFeedbackManager.shared.impact(.light)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            isBarExpanding = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showingSearchSheet = true
        }
    }

    private var floatingBottomBar: some View {
        HStack(spacing: 10) {
            // Search pill
            Button {
                triggerSearchSheet()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("Search places...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(UIColor.systemBackground).opacity(0.85))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // Layers button
            if !isBarExpanding {
                Button {
                    HapticFeedbackManager.shared.impact(.light)
                    navigationPath.append("layers")
                } label: {
                    Image(systemName: "square.stack.3d.down.right.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 46, height: 46)
                        .background(Color(UIColor.systemBackground).opacity(0.85))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 4)
    }

    // MARK: - Navigation

    private func navigateToResult(_ mapItem: MKMapItem) {
        let name = mapItem.name ?? "Unknown Place"
        let coordinate = mapItem.placemark.location?.coordinate ?? mapCenterCoordinate
        let category = PlaceCategory.from(mapItem: mapItem)
        let stablePlaceId = FavoriteLocation.stablePlaceId(name: name, coordinate: coordinate)
        let favorite = favoritesManager.getFavorite(for: stablePlaceId)

        let favoriteStatus: LocationDetail.FavoriteStatus
        if let fav = favorite {
            favoriteStatus = .favorited(rating: fav.rating ?? 0, notes: fav.notes)
        } else {
            favoriteStatus = .notFavorited
        }

        searchResultPin = POIAnnotation(coordinate: coordinate, title: name, subtitle: category.rawValue)
        navigateToCoordinate = coordinate

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            selectedLocationDetail = LocationDetail(
                name: name,
                category: category,
                coordinate: coordinate,
                address: mapItem.placemark.title,
                phoneNumber: mapItem.phoneNumber,
                website: nil,
                hours: nil,
                images: [],
                rating: nil,
                priceLevel: nil,
                amenities: [],
                userFavoriteStatus: favoriteStatus
            )
            HapticFeedbackManager.shared.impact(.light)
        }
    }

    private func navigateToFavorite(_ favorite: FavoriteLocation) {
        let favoriteStatus: LocationDetail.FavoriteStatus = .favorited(
            rating: favorite.rating ?? 0,
            notes: favorite.notes
        )

        searchResultPin = POIAnnotation(
            coordinate: favorite.coordinate,
            title: favorite.name,
            subtitle: favorite.category.rawValue
        )
        navigateToCoordinate = favorite.coordinate

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            selectedLocationDetail = LocationDetail(
                name: favorite.name,
                category: favorite.category,
                coordinate: favorite.coordinate,
                address: nil,
                phoneNumber: nil,
                website: nil,
                hours: nil,
                images: [],
                rating: favorite.rating.map { Double($0) },
                priceLevel: nil,
                amenities: [],
                userFavoriteStatus: favoriteStatus
            )
            HapticFeedbackManager.shared.impact(.light)
        }
    }
}

// MARK: - Map Search Sheet

struct MapSearchSheet: View {
    let mapCenter: CLLocationCoordinate2D
    @ObservedObject var favoritesManager: InAppFavoritesManager
    let onSelectResult: (MKMapItem) -> Void
    let onSelectFavorite: (FavoriteLocation) -> Void

    @StateObject private var searchCompleter = PlaceSearchCompleter()
    @StateObject private var forYouLoader = ForYouRecommendationLoader()
    @StateObject private var locationManager = LocationManager()
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var showingSuggestions = true
    @State private var suppressNextSearchChange = false
    @FocusState private var isFieldFocused: Bool

    /// User's current location for distance display, falls back to map center
    private var userLocation: CLLocationCoordinate2D {
        locationManager.latestLocation?.coordinate ?? mapCenter
    }

    private let categories: [(label: String, icon: String, poiCategories: [MKPointOfInterestCategory])] = [
        ("Restaurants", "fork.knife", [.restaurant, .bakery, .foodMarket]),
        ("Coffee", "cup.and.saucer", [.cafe]),
        ("Bars", "wineglass", [.nightlife, .brewery, .winery]),
        ("Parks", "tree", [.park, .nationalPark, .beach]),
        ("Shopping", "bag", [.store]),
        ("Fitness", "dumbbell", [.fitnessCenter]),
    ]

    private let categorySearchRadius: CLLocationDistance = 4828

    /// Favorites sorted by proximity to user's current location
    private var nearbyFavorites: [FavoriteLocation] {
        let userLoc = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        return favoritesManager.favorites.sorted { a, b in
            let distA = CLLocation(latitude: a.coordinate.latitude, longitude: a.coordinate.longitude).distance(from: userLoc)
            let distB = CLLocation(latitude: b.coordinate.latitude, longitude: b.coordinate.longitude).distance(from: userLoc)
            return distA < distB
        }
    }

    private var isActivelySearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search places...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .focused($isFieldFocused)
                    .onSubmit { performSearch() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                        searchCompleter.clear()
                        showingSuggestions = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(UIColor.tertiarySystemFill))
            .clipShape(Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Category chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.label) { cat in
                        Button {
                            performCategorySearch(poiCategories: cat.poiCategories, label: cat.label)
                        } label: {
                            Label(cat.label, systemImage: cat.icon)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(UIColor.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 14)

            Divider()
                .padding(.top, 12)

            // Content
            if isSearching {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Searching...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if isActivelySearching && showingSuggestions && !searchCompleter.suggestions.isEmpty {
                List {
                    ForEach(searchCompleter.suggestions, id: \.self) { suggestion in
                        Button {
                            resolveSuggestionAndNavigate(suggestion)
                        } label: {
                            SuggestionRowView(suggestion: suggestion)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            } else if !showingSuggestions && !searchResults.isEmpty {
                List {
                    ForEach(searchResults, id: \.self) { mapItem in
                        Button {
                            onSelectResult(mapItem)
                        } label: {
                            SearchResultRowView(mapItem: mapItem, favoritesManager: favoritesManager)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            } else if !isActivelySearching {
                // Default: Favorite Places + For You carousels
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Favorite Places
                        if !nearbyFavorites.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Favorite Places")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(nearbyFavorites) { favorite in
                                            FavoriteCardView(
                                                favorite: favorite,
                                                userLocation: userLocation
                                            ) {
                                                onSelectFavorite(favorite)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        // For You
                        if !forYouLoader.recommendations.isEmpty || forYouLoader.isLoading {
                            VStack(alignment: .leading, spacing: 10) {
                                if forYouLoader.isLoading && forYouLoader.recommendations.isEmpty {
                                    HStack(spacing: 6) {
                                        ProgressView().scaleEffect(0.6)
                                        Text("Finding places for you...")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                } else {
                                    Text("For You")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 16)
                                }

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        if forYouLoader.isLoading && forYouLoader.recommendations.isEmpty {
                                            ForEach(0..<4, id: \.self) { _ in
                                                SkeletonForYouCard()
                                            }
                                        } else {
                                            ForEach(forYouLoader.recommendations, id: \.self) { mapItem in
                                                ForYouCardView(mapItem: mapItem, userLocation: userLocation) {
                                                    onSelectResult(mapItem)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        // Subtle empty nudge
                        if nearbyFavorites.isEmpty && forYouLoader.recommendations.isEmpty && !forYouLoader.isLoading {
                            VStack(spacing: 8) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.largeTitle)
                                    .foregroundStyle(.quaternary)
                                Text("Search for places nearby")
                                    .font(.subheadline)
                                    .foregroundStyle(.quaternary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        }
                    }
                    .padding(.top, 14)
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No results found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .fontDesign(.rounded)
        .onAppear {
            locationManager.requestAuthorization()
            searchCompleter.updateRegion(
                MKCoordinateRegion(center: mapCenter, latitudinalMeters: 10000, longitudinalMeters: 10000)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                isFieldFocused = true
            }
            // Load "For You" recommendations based on user's favorites
            forYouLoader.loadRecommendations(
                favorites: favoritesManager.favorites,
                near: mapCenter
            )
        }
        .onChange(of: searchText) { _, newValue in
            if suppressNextSearchChange {
                suppressNextSearchChange = false
                return
            }
            showingSuggestions = true
            searchCompleter.search(newValue)
        }
    }

    // MARK: - Search Actions

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isSearching = true
        showingSuggestions = false
        searchCompleter.clear()
        isFieldFocused = false

        ManualLocationImporter.searchByName(query, near: mapCenter) { mapItems in
            self.searchResults = mapItems
            self.isSearching = false
        }
    }

    private func performCategorySearch(poiCategories: [MKPointOfInterestCategory], label: String) {
        isSearching = true
        showingSuggestions = false
        searchCompleter.clear()
        suppressNextSearchChange = true
        searchText = label
        isFieldFocused = false

        // Use MKLocalPointsOfInterestRequest for pure category filtering (no text matching)
        let region = MKCoordinateRegion(
            center: mapCenter,
            latitudinalMeters: categorySearchRadius,
            longitudinalMeters: categorySearchRadius
        )
        let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: poiCategories)

        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                self.searchResults = response?.mapItems ?? []
                self.isSearching = false
            }
        }
    }

    private func resolveSuggestionAndNavigate(_ suggestion: MKLocalSearchCompletion) {
        isFieldFocused = false

        let request = MKLocalSearch.Request(completion: suggestion)
        request.region = MKCoordinateRegion(center: mapCenter, latitudinalMeters: 10000, longitudinalMeters: 10000)

        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                if let firstItem = response?.mapItems.first {
                    onSelectResult(firstItem)
                }
            }
        }
    }
}

// MARK: - For You Recommendation Loader

@MainActor
final class ForYouRecommendationLoader: ObservableObject {
    @Published var recommendations: [MKMapItem] = []
    @Published var serverResults: [PlaceSearchResult] = []
    @Published var isLoading = false

    /// Load recommendations — tries server-backed blended search first, falls back to local MapKit.
    func loadRecommendations(favorites: [FavoriteLocation], near center: CLLocationCoordinate2D) {
        guard !favorites.isEmpty else { return }
        isLoading = true

        // Try server first if authenticated
        if BackendClient.shared.isAuthenticated {
            loadFromServer(favorites: favorites, near: center)
        } else {
            loadFromMapKit(favorites: favorites, near: center)
        }
    }

    // MARK: - Server-backed (aligned-user recommendations)

    private func loadFromServer(favorites: [FavoriteLocation], near center: CLLocationCoordinate2D) {
        Task { @MainActor in
            do {
                let calendar = Calendar.current
                let now = Date()
                let request = RecommendationRequest(
                    location: Coordinate(latitude: center.latitude, longitude: center.longitude),
                    currentHour: calendar.component(.hour, from: now),
                    currentDayOfWeek: calendar.component(.weekday, from: now) - 1,
                    limit: 12
                )
                let response = try await BackendClient.shared.getRecommendations(request)

                if response.recommendations.isEmpty {
                    // No aligned-user data yet — fall back to blended search
                    loadFromBlendedSearch(favorites: favorites, near: center)
                    return
                }

                self.recommendations = response.recommendations.map { rec in
                    let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(
                        latitude: rec.latitude, longitude: rec.longitude
                    ))
                    let item = MKMapItem(placemark: placemark)
                    item.name = rec.name
                    return item
                }
                self.isLoading = false
            } catch {
                print("[ForYou] recommendations failed, falling back to search: \(error.localizedDescription)")
                loadFromBlendedSearch(favorites: favorites, near: center)
            }
        }
    }

    private func loadFromBlendedSearch(favorites: [FavoriteLocation], near center: CLLocationCoordinate2D) {
        var categoryCounts: [PlaceCategory: Int] = [:]
        for fav in favorites { categoryCounts[fav.category, default: 0] += 1 }
        let topCategory = categoryCounts.sorted { $0.value > $1.value }.first?.key ?? .restaurant
        let queryMap: [PlaceCategory: String] = [
            .restaurant: "restaurant", .cafe: "coffee cafe", .bar: "bar cocktails",
            .park: "park outdoor", .shopping: "shop boutique", .gym: "fitness gym",
            .museum: "museum gallery", .library: "bookstore", .nightclub: "nightlife",
        ]
        let query = queryMap[topCategory] ?? "things to do"

        Task { @MainActor in
            do {
                let request = PlaceSearchRequest(
                    query: query,
                    location: Coordinate(latitude: center.latitude, longitude: center.longitude),
                    radiusKm: 5.0, limit: 12
                )
                let response = try await BackendClient.shared.searchPlaces(request)
                let favIDs = Set(favorites.map { $0.placeId })
                let filtered = response.results.filter { result in
                    let pid = "\(result.name)_\(String(format: "%.5f", result.location.latitude))_\(String(format: "%.5f", result.location.longitude))"
                    return !favIDs.contains(pid)
                }
                self.recommendations = filtered.prefix(12).map { result in
                    let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(
                        latitude: result.location.latitude, longitude: result.location.longitude
                    ))
                    let item = MKMapItem(placemark: placemark)
                    item.name = result.name
                    return item
                }
                self.isLoading = false
            } catch {
                loadFromMapKit(favorites: favorites, near: center)
            }
        }
    }

    // MARK: - Local MapKit fallback

    private func loadFromMapKit(favorites: [FavoriteLocation], near center: CLLocationCoordinate2D) {
        var categoryCounts: [PlaceCategory: Int] = [:]
        for fav in favorites {
            categoryCounts[fav.category, default: 0] += 1
        }

        let topCategories = categoryCounts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }

        let queryMap: [PlaceCategory: String] = [
            .restaurant: "restaurant food dining",
            .cafe: "coffee tea cafe bakery",
            .bar: "bar cocktail lounge",
            .park: "park garden trail outdoor",
            .shopping: "boutique shop store",
            .gym: "fitness studio yoga",
            .museum: "museum gallery art",
            .library: "bookstore library",
            .nightclub: "live music venue nightlife",
            .other: "things to do",
        ]

        let queries = topCategories.compactMap { queryMap[$0] ?? queryMap[.other] }
        guard !queries.isEmpty else {
            isLoading = false
            return
        }

        let favoritePlaceIds = Set(favorites.map { $0.placeId })
        let group = DispatchGroup()
        var allItems: [MKMapItem] = []
        let lock = NSLock()

        for query in queries {
            group.enter()
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: 5000,
                longitudinalMeters: 5000
            )

            MKLocalSearch(request: request).start { response, _ in
                if let items = response?.mapItems {
                    lock.lock()
                    allItems.append(contentsOf: items)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            var seen = Set<String>()
            let center = CLLocation(latitude: center.latitude, longitude: center.longitude)

            let filtered = allItems
                .filter { item in
                    guard let name = item.name else { return false }
                    if let coord = item.placemark.location?.coordinate {
                        let pid = FavoriteLocation.stablePlaceId(name: name, coordinate: coord)
                        if favoritePlaceIds.contains(pid) { return false }
                    }
                    if seen.contains(name) { return false }
                    seen.insert(name)
                    return true
                }
                .sorted { a, b in
                    let dA = (a.placemark.location ?? CLLocation()).distance(from: center)
                    let dB = (b.placemark.location ?? CLLocation()).distance(from: center)
                    return dA < dB
                }

            self.recommendations = Array(filtered.prefix(12))
            self.isLoading = false
        }
    }
}

// MARK: - Favorite Card

private struct FavoriteCardView: View {
    let favorite: FavoriteLocation
    let userLocation: CLLocationCoordinate2D
    let onTap: () -> Void

    private var distanceString: String {
        let user = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let loc = CLLocation(latitude: favorite.coordinate.latitude, longitude: favorite.coordinate.longitude)
        let meters = loc.distance(from: user)

        if meters < 1609 {
            let feet = Int(meters * 3.281)
            return "\(feet) ft"
        } else {
            let miles = meters / 1609.34
            return String(format: "%.1f mi", miles)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: favorite.category.iconName)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(UIColor.quaternarySystemFill))
                    .clipShape(Circle())

                Text(favorite.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(distanceString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120, alignment: .leading)
            .padding(12)
            .background(Color(UIColor.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - For You Card

private struct ForYouCardView: View {
    let mapItem: MKMapItem
    let userLocation: CLLocationCoordinate2D
    let onTap: () -> Void

    private var name: String { mapItem.name ?? "Unknown" }
    private var category: PlaceCategory { PlaceCategory.from(mapItem: mapItem) }

    private var distanceString: String {
        let user = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let loc = mapItem.placemark.location ?? CLLocation()
        let meters = loc.distance(from: user)

        if meters < 1609 {
            let feet = Int(meters * 3.281)
            return "\(feet) ft"
        } else {
            let miles = meters / 1609.34
            return String(format: "%.1f mi", miles)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: category.iconName)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(UIColor.quaternarySystemFill))
                    .clipShape(Circle())

                Text(name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(distanceString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120, alignment: .leading)
            .padding(12)
            .background(Color(UIColor.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skeleton For You Card

private struct SkeletonForYouCard: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Circle()
                .fill(.quaternary)
                .frame(width: 36, height: 36)

            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 80, height: 12)

            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 50, height: 10)
        }
        .frame(width: 120, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(shimmer ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}

// MARK: - Search Result Row

private struct SearchResultRowView: View {
    let mapItem: MKMapItem
    @ObservedObject var favoritesManager: InAppFavoritesManager

    private var name: String { mapItem.name ?? "Unknown Place" }
    private var coordinate: CLLocationCoordinate2D {
        mapItem.placemark.location?.coordinate ?? CLLocationCoordinate2D()
    }
    private var stablePlaceId: String {
        FavoriteLocation.stablePlaceId(name: name, coordinate: coordinate)
    }
    private var isFavorited: Bool { favoritesManager.isFavorited(stablePlaceId) }
    private var category: PlaceCategory { PlaceCategory.from(mapItem: mapItem) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.iconName)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let address = mapItem.placemark.title {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button { toggleFavorite() } label: {
                Image(systemName: isFavorited ? "star.fill" : "star")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isFavorited ? .yellow : .secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func toggleFavorite() {
        if isFavorited {
            favoritesManager.removeFavorite(for: stablePlaceId)
        } else {
            favoritesManager.quickFavorite(name: name, category: category, coordinate: coordinate)
        }
        HapticFeedbackManager.shared.impact(.light)
    }
}

// MARK: - Supporting Views

struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

struct LayersButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environmentObject(InAppFavoritesManager())
}
