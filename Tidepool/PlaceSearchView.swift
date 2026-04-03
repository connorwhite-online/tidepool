import SwiftUI
import MapKit
import CoreLocation

// MARK: - Search Completer (typeahead suggestions as you type)

final class PlaceSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    @Published var isCompleting: Bool = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func updateRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    func search(_ fragment: String) {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            isCompleting = false
            return
        }
        isCompleting = true
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
        isCompleting = false
        completer.cancel()
    }

    // MARK: MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.suggestions = completer.results
            self.isCompleting = false
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.isCompleting = false
        }
    }
}

// MARK: - PlaceSearchView

struct PlaceSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var favoritesManager: InAppFavoritesManager
    @StateObject private var locationManager = LocationManager()
    @StateObject private var searchCompleter = PlaceSearchCompleter()

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var showingSuggestions = true // Show suggestions vs full results

    private let categories: [(label: String, icon: String, poiCategories: [MKPointOfInterestCategory])] = [
        ("Restaurants", "fork.knife", [.restaurant, .bakery, .foodMarket]),
        ("Coffee", "cup.and.saucer", [.cafe]),
        ("Bars", "wineglass", [.nightlife, .brewery, .winery]),
        ("Parks", "tree", [.park, .nationalPark, .beach]),
        ("Shopping", "bag", [.store]),
        ("Fitness", "dumbbell", [.fitnessCenter]),
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search for a place...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { performFullSearch() }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchResults = []
                            searchCompleter.clear()
                            showingSuggestions = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        performFullSearch()
                    } label: {
                        Text("Search")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .opacity(searchText.isEmpty ? 0.4 : 1)
                    .disabled(searchText.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.top, 8)

                // Category chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.label) { cat in
                            Button {
                                searchText = cat.label
                                performCategorySearch(poiCategories: cat.poiCategories, label: cat.label)
                            } label: {
                                Label(cat.label, systemImage: cat.icon)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 10)

                Divider()

                // Content: suggestions, full results, or empty state
                if isSearching {
                    List {
                        ForEach(0..<4, id: \.self) { _ in
                            SkeletonPlaceRow()
                        }
                    }
                    .listStyle(.plain)
                } else if showingSuggestions && !searchCompleter.suggestions.isEmpty {
                    // Typeahead suggestions
                    List {
                        ForEach(searchCompleter.suggestions, id: \.self) { suggestion in
                            Button {
                                selectSuggestion(suggestion)
                            } label: {
                                SuggestionRowView(suggestion: suggestion)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                } else if !showingSuggestions && !searchResults.isEmpty {
                    // Full search results
                    List {
                        ForEach(searchResults, id: \.self) { mapItem in
                            PlaceSearchRowView(mapItem: mapItem, favoritesManager: favoritesManager)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "Search for places to add to favorites" : (searchCompleter.isCompleting ? "Searching..." : "No results found"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .navigationTitle("Add Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                locationManager.requestAuthorization()
                updateCompleterRegion()
            }
            .onChange(of: searchText) { _, newValue in
                // Live typeahead as user types
                showingSuggestions = true
                searchCompleter.search(newValue)
            }
            .onChange(of: locationManager.latestLocation) { _, _ in
                updateCompleterRegion()
            }
        }
    }

    private func updateCompleterRegion() {
        let coordinate = locationManager.latestLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 34.096, longitude: -118.273)
        searchCompleter.updateRegion(
            MKCoordinateRegion(center: coordinate, latitudinalMeters: 10000, longitudinalMeters: 10000)
        )
    }

    private func performFullSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isSearching = true
        showingSuggestions = false
        searchCompleter.clear()

        let coordinate = locationManager.latestLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 34.096, longitude: -118.273)

        ManualLocationImporter.searchByName(query, near: coordinate) { mapItems in
            self.searchResults = mapItems
            self.isSearching = false
        }
    }

    private func performCategorySearch(poiCategories: [MKPointOfInterestCategory], label: String) {
        isSearching = true
        showingSuggestions = false
        searchCompleter.clear()

        let coordinate = locationManager.latestLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 34.096, longitude: -118.273)

        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
        let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: poiCategories)

        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                self.searchResults = response?.mapItems ?? []
                self.isSearching = false
            }
        }
    }

    private func selectSuggestion(_ suggestion: MKLocalSearchCompletion) {
        // Use the suggestion to perform a targeted MKLocalSearch
        isSearching = true
        showingSuggestions = false
        searchText = suggestion.title

        let request = MKLocalSearch.Request(completion: suggestion)
        let coordinate = locationManager.latestLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 34.096, longitude: -118.273)
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 10000, longitudinalMeters: 10000)

        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                self.searchResults = response?.mapItems ?? []
                self.isSearching = false
            }
        }
    }
}

// MARK: - Suggestion Row (typeahead)

struct SuggestionRowView: View {
    let suggestion: MKLocalSearchCompletion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "arrow.up.left")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Place Search Row (full results)

struct PlaceSearchRowView: View {
    let mapItem: MKMapItem
    @ObservedObject var favoritesManager: InAppFavoritesManager

    private var name: String {
        mapItem.name ?? "Unknown Place"
    }

    private var coordinate: CLLocationCoordinate2D {
        mapItem.placemark.location?.coordinate ?? CLLocationCoordinate2D()
    }

    private var stablePlaceId: String {
        FavoriteLocation.stablePlaceId(name: name, coordinate: coordinate)
    }

    private var isFavorited: Bool {
        favoritesManager.isFavorited(stablePlaceId)
    }

    private var category: PlaceCategory {
        PlaceCategory.from(mapItem: mapItem)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.iconName)
                .font(.title3)
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

            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorited ? "star.fill" : "star")
                    .font(.subheadline)
                    .foregroundStyle(isFavorited ? .yellow : .secondary)
                    .frame(width: 44, height: 44)
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
            favoritesManager.quickFavorite(
                name: name,
                category: category,
                coordinate: coordinate
            )
        }
        HapticFeedbackManager.shared.impact(.light)
    }
}

// MARK: - Skeleton Loading Row

struct SkeletonPlaceRow: View {
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 140, height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 200, height: 10)
            }

            Spacer()

            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 24, height: 24)
        }
        .padding(.vertical, 2)
        .opacity(shimmer ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}
