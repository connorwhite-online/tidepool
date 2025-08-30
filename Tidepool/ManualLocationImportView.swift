import SwiftUI
import MapKit
import CoreLocation

struct ManualLocationImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appleMapsManager: AppleMapsIntegrationManager
    @StateObject private var locationManager = LocationManager()
    
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var selectedCategory: PlaceCategory = .restaurant
    @State private var showingCategoryPicker = false
    
    private let searchCategories = [
        ("My favorites", "heart.fill", "restaurant cafe bar gym park museum"),
        ("Restaurants", "fork.knife", "restaurant"),
        ("Coffee & Cafés", "cup.and.saucer", "coffee cafe starbucks"),
        ("Bars & Nightlife", "wineglass", "bar pub nightclub"),
        ("Fitness & Gyms", "dumbbell", "gym fitness yoga"),
        ("Parks & Outdoor", "tree", "park beach hiking trail"),
        ("Shopping", "bag", "shopping mall store"),
        ("Entertainment", "tv", "movie theater museum")
    ]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add Your Favorite Places")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Search for places you visit regularly and love. We'll use these to:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                                Text("Personalize your map recommendations")
                                    .font(.caption)
                            }
                            HStack {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                Text("Build your interest profile")
                                    .font(.caption)
                            }
                            HStack {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text("Find similar places nearby")
                                    .font(.caption)
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(.horizontal)
                .padding(.top)
                
                // Search Section
                VStack(spacing: 16) {
                    // Search Bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        
                        TextField("Search for places...", text: $searchText)
                            .textFieldStyle(.plain)
                            .onSubmit { performSearch() }
                        
                        if !searchText.isEmpty {
                            Button("Clear") {
                                searchText = ""
                                searchResults = []
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    
                    // Quick Search Categories
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(searchCategories, id: \.0) { category in
                                Button {
                                    searchText = category.2
                                    performSearch()
                                } label: {
                                    Label(category.0, systemImage: category.1)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(.quaternary)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.horizontal)
                .padding(.top)
                
                // Results List
                if isSearching {
                    VStack {
                        ProgressView()
                            .padding()
                        Text("Searching nearby places...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty && !searchText.isEmpty {
                    VStack {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No places found")
                            .font(.headline)
                        Text("Try searching with different keywords")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(searchResults, id: \.self) { mapItem in
                            PlaceRowView(
                                mapItem: mapItem,
                                onAdd: { location in
                                    appleMapsManager.addLocation(location)
                                }
                            )
                        }
                    }
                    .listStyle(.plain)
                }
                
                Spacer()
            }
            .navigationTitle("Add Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
                    .onAppear {
            // Request location permission for better search results
            locationManager.requestAuthorization()
            
            if let userLocation = locationManager.latestLocation {
                // Suggest nearby popular places
                searchNearbyPopularPlaces(coordinate: userLocation.coordinate)
            }
        }
        }
    }
    
    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let userLocation = locationManager.latestLocation else { return }
        
        isSearching = true
        
        ManualLocationImporter.searchByName(
            searchText,
            near: userLocation.coordinate
        ) { mapItems in
            self.searchResults = mapItems
            self.isSearching = false
        }
    }
    
    private func searchNearbyPopularPlaces(coordinate: CLLocationCoordinate2D) {
        ManualLocationImporter.searchNearby(coordinate: coordinate) { mapItems in
            // Show a curated selection of nearby popular places
            self.searchResults = Array(mapItems.prefix(20))
        }
    }
}

struct PlaceRowView: View {
    let mapItem: MKMapItem
    let onAdd: (SavedLocation) -> Void
    
    @State private var isAdded = false
    @State private var selectedCategory: PlaceCategory
    @State private var showingCategoryPicker = false
    
    init(mapItem: MKMapItem, onAdd: @escaping (SavedLocation) -> Void) {
        self.mapItem = mapItem
        self.onAdd = onAdd
        self._selectedCategory = State(initialValue: PlaceCategory.from(mapItem: mapItem))
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(mapItem.name ?? "Unknown Place")
                    .font(.headline)
                    .lineLimit(1)
                
                if let address = mapItem.placemark.title {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                // Category selector
                Button {
                    showingCategoryPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedCategory.iconName)
                        Text(selectedCategory.displayName)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            Button {
                addLocation()
            } label: {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title2)
                    .foregroundStyle(isAdded ? .green : .accentColor)
            }
            .disabled(isAdded)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Select Category", isPresented: $showingCategoryPicker) {
            ForEach(PlaceCategory.allCases, id: \.self) { category in
                Button(category.displayName) {
                    selectedCategory = category
                }
            }
        }
    }
    
    private func addLocation() {
        guard let coordinate = mapItem.placemark.location?.coordinate else { return }
        
        let location = SavedLocation(
            name: mapItem.name ?? "Unknown Place",
            coordinate: coordinate,
            category: selectedCategory,
            address: mapItem.placemark.title,
            source: .appleMaps
        )
        
        onAdd(location)
        isAdded = true
        
        // Add haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        
        // Visual feedback
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            // Animation handled by state change
        }
    }
}

#Preview {
    ManualLocationImportView(appleMapsManager: AppleMapsIntegrationManager())
}
