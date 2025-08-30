import Foundation
import MapKit
import CoreLocation

// MARK: - Data Models

/// Represents a saved location that can be imported or manually added by the user
struct SavedLocation: Codable, Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let category: PlaceCategory
    let address: String?
    let createdAt: Date
    let source: LocationSource
    
    enum LocationSource: String, Codable, CaseIterable {
        case manual = "manual"
        case appleMaps = "apple_maps" 
        case photos = "photos"
        case inApp = "in_app"
    }
    
    enum CodingKeys: String, CodingKey {
        case name, category, address, createdAt, source
        case latitude, longitude
    }
    
    init(name: String, coordinate: CLLocationCoordinate2D, category: PlaceCategory, address: String? = nil, source: LocationSource = .manual) {
        self.name = name
        self.coordinate = coordinate
        self.category = category
        self.address = address
        self.createdAt = Date()
        self.source = source
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(PlaceCategory.self, forKey: .category)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        source = try container.decode(LocationSource.self, forKey: .source)
        
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(source, forKey: .source)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
    }
}

// MARK: - SavedLocation Hashable and Equatable conformance

extension SavedLocation: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension SavedLocation: Equatable {
    static func == (lhs: SavedLocation, rhs: SavedLocation) -> Bool {
        return lhs.id == rhs.id
    }
}

/// Place categories that map to interest tags for the recommendation system
enum PlaceCategory: String, Codable, CaseIterable {
    // Food & Dining
    case restaurant = "restaurant"
    case cafe = "cafe"
    case bar = "bar"
    case fastFood = "fast_food"
    case fineDining = "fine_dining"
    case bakery = "bakery"
    
    // Entertainment & Recreation
    case movie = "movie_theater"
    case park = "park"
    case gym = "gym"
    case museum = "museum"
    case theater = "theater"
    case nightclub = "nightclub"
    case beach = "beach"
    case hiking = "hiking"
    
    // Shopping
    case shopping = "shopping"
    case bookstore = "bookstore"
    case grocery = "grocery"
    case mall = "mall"
    
    // Services
    case hospital = "hospital"
    case school = "school"
    case library = "library"
    case gasStation = "gas_station"
    case bank = "bank"
    
    // Travel & Transportation
    case hotel = "hotel"
    case airport = "airport"
    case trainStation = "train_station"
    
    // Other
    case office = "office"
    case home = "home"
    case other = "other"
    
    var displayName: String {
        switch self {
        case .restaurant: return "Restaurant"
        case .cafe: return "Café"
        case .bar: return "Bar"
        case .fastFood: return "Fast Food"
        case .fineDining: return "Fine Dining"
        case .bakery: return "Bakery"
        case .movie: return "Movie Theater"
        case .park: return "Park"
        case .gym: return "Gym"
        case .museum: return "Museum"
        case .theater: return "Theater"
        case .nightclub: return "Nightclub"
        case .beach: return "Beach"
        case .hiking: return "Hiking Trail"
        case .shopping: return "Shopping"
        case .bookstore: return "Bookstore"
        case .grocery: return "Grocery Store"
        case .mall: return "Shopping Mall"
        case .hospital: return "Hospital"
        case .school: return "School"
        case .library: return "Library"
        case .gasStation: return "Gas Station"
        case .bank: return "Bank"
        case .hotel: return "Hotel"
        case .airport: return "Airport"
        case .trainStation: return "Train Station"
        case .office: return "Office"
        case .home: return "Home"
        case .other: return "Other"
        }
    }
    
    var iconName: String {
        switch self {
        case .restaurant: return "fork.knife"
        case .cafe: return "cup.and.saucer"
        case .bar: return "wineglass"
        case .fastFood: return "takeoutbag.and.cup.and.straw"
        case .fineDining: return "fork.knife.circle"
        case .bakery: return "birthday.cake"
        case .movie: return "tv"
        case .park: return "tree"
        case .gym: return "dumbbell"
        case .museum: return "building.columns"
        case .theater: return "theatermasks"
        case .nightclub: return "music.note.house"
        case .beach: return "sun.max"
        case .hiking: return "figure.hiking"
        case .shopping: return "bag"
        case .bookstore: return "book"
        case .grocery: return "cart"
        case .mall: return "building.2"
        case .hospital: return "cross.case"
        case .school: return "graduationcap"
        case .library: return "books.vertical"
        case .gasStation: return "fuelpump"
        case .bank: return "dollarsign.circle"
        case .hotel: return "bed.double"
        case .airport: return "airplane"
        case .trainStation: return "tram"
        case .office: return "building"
        case .home: return "house"
        case .other: return "mappin"
        }
    }
    
    /// Convert MKMapItem category to our PlaceCategory
    static func from(mapItem: MKMapItem) -> PlaceCategory {
        // Extract category from MKMapItem - this is a simplified mapping
        // In a real implementation, you'd want more sophisticated category detection
        let name = mapItem.name?.lowercased() ?? ""
        let category = mapItem.pointOfInterestCategory
        
        if let category = category {
            switch category {
            case .restaurant, .foodMarket: return .restaurant
            case .cafe: return .cafe
            case .nightlife: return .bar
            case .store: return .shopping
            case .park: return .park
            case .museum: return .museum
            case .theater: return .theater
            case .hospital: return .hospital
            case .school: return .school
            case .library: return .library
            case .gasStation: return .gasStation
            case .bank: return .bank
            case .hotel: return .hotel
            case .airport: return .airport
            default: break
            }
        }
        
        // Fallback to name-based detection
        if name.contains("coffee") || name.contains("cafe") || name.contains("starbucks") {
            return .cafe
        } else if name.contains("restaurant") || name.contains("dining") {
            return .restaurant
        } else if name.contains("bar") || name.contains("pub") {
            return .bar
        } else if name.contains("gym") || name.contains("fitness") {
            return .gym
        } else if name.contains("park") {
            return .park
        }
        
        return .other
    }
    
    /// Generate interest tags for the recommendation system
    var interestTags: [String] {
        switch self {
        case .restaurant, .fineDining:
            return ["dining", "restaurant", "food", "social"]
        case .cafe:
            return ["coffee", "cafe", "social", "work", "casual_dining"]
        case .bar, .nightclub:
            return ["nightlife", "drinks", "social", "entertainment"]
        case .fastFood:
            return ["fast_food", "convenience", "dining"]
        case .bakery:
            return ["bakery", "sweets", "coffee", "casual"]
        case .movie:
            return ["movies", "entertainment", "social", "indoor"]
        case .park, .beach, .hiking:
            return ["outdoor", "nature", "recreation", "exercise"]
        case .gym:
            return ["fitness", "health", "exercise", "indoor"]
        case .museum:
            return ["culture", "art", "education", "indoor"]
        case .theater:
            return ["culture", "entertainment", "arts", "social"]
        case .shopping, .mall:
            return ["shopping", "retail", "social", "indoor"]
        case .bookstore:
            return ["books", "culture", "education", "quiet"]
        case .library:
            return ["books", "study", "quiet", "education"]
        case .grocery:
            return ["grocery", "convenience", "daily_life"]
        default:
            return ["general"]
        }
    }
}

// MARK: - Apple Maps Integration Manager

@MainActor
class AppleMapsIntegrationManager: ObservableObject {
    @Published var savedLocations: [SavedLocation] = []
    @Published var isEnabled: Bool = false
    @Published var lastSync: Date?
    @Published var isImporting: Bool = false
    @Published var importError: String?
    
    private let userDefaults = UserDefaults.standard
    private let savedLocationsKey = "apple_maps_saved_locations"
    private let enabledKey = "apple_maps_integration_enabled"
    private let lastSyncKey = "apple_maps_last_sync"
    
    init() {
        loadSavedLocations()
        isEnabled = userDefaults.bool(forKey: enabledKey)
        lastSync = userDefaults.object(forKey: lastSyncKey) as? Date
    }
    
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
        
        if !enabled {
            clearAppleMapsLocations()
        }
    }
    
    /// Add a location manually (simulating Apple Maps import)
    func addLocation(_ location: SavedLocation) {
        savedLocations.append(location)
        saveToDisk()
    }
    
    /// Remove a location
    func removeLocation(_ location: SavedLocation) {
        savedLocations.removeAll { $0.id == location.id }
        saveToDisk()
    }
    
    /// Get interest tags from all saved locations
    func getInterestTags() -> [String: Int] {
        var tagCounts: [String: Int] = [:]
        
        for location in savedLocations where location.source == .appleMaps || location.source == .manual {
            for tag in location.category.interestTags {
                tagCounts[tag, default: 0] += 1
            }
        }
        
        return tagCounts
    }
    
    /// Generate normalized interest vector from tags
    func getInterestVector() -> [Float] {
        let tagCounts = getInterestTags()
        
        // Define a canonical vocabulary of tags (this would be expanded)
        let vocabulary = [
            "dining", "coffee", "nightlife", "outdoor", "fitness", "culture",
            "shopping", "entertainment", "social", "nature", "health", "education",
            "quiet", "convenience", "recreation", "arts", "indoor", "exercise"
        ]
        
        // Create vector with TF-IDF-like weighting
        var vector: [Float] = Array(repeating: 0.0, count: vocabulary.count)
        let totalLocations = Float(savedLocations.count)
        
        for (index, tag) in vocabulary.enumerated() {
            if let count = tagCounts[tag], totalLocations > 0 {
                // Simple frequency normalization
                vector[index] = Float(count) / totalLocations
            }
        }
        
        // Normalize vector
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            vector = vector.map { $0 / magnitude }
        }
        
        return vector
    }
    
    /// Import locations from MKMapItems (for manual import flow)
    func importFromMapItems(_ mapItems: [MKMapItem]) {
        let newLocations = mapItems.compactMap { mapItem -> SavedLocation? in
            guard let name = mapItem.name,
                  let coordinate = mapItem.placemark.location?.coordinate else { return nil }
            
            let category = PlaceCategory.from(mapItem: mapItem)
            let address = mapItem.placemark.thoroughfare ?? mapItem.placemark.locality
            
            return SavedLocation(
                name: name,
                coordinate: coordinate,
                category: category,
                address: address,
                source: .appleMaps
            )
        }
        
        savedLocations.append(contentsOf: newLocations)
        lastSync = Date()
        userDefaults.set(lastSync, forKey: lastSyncKey)
        saveToDisk()
    }
    
    private func clearAppleMapsLocations() {
        savedLocations.removeAll { $0.source == .appleMaps }
        saveToDisk()
    }
    
    private func loadSavedLocations() {
        guard let data = userDefaults.data(forKey: savedLocationsKey),
              let locations = try? JSONDecoder().decode([SavedLocation].self, from: data) else {
            return
        }
        savedLocations = locations
    }
    
    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(savedLocations) else { return }
        userDefaults.set(data, forKey: savedLocationsKey)
    }
}

// MARK: - Manual Import Helper

struct ManualLocationImporter {
    static func searchNearby(coordinate: CLLocationCoordinate2D, completion: @escaping ([MKMapItem]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "restaurant cafe bar gym park" // General search
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
        
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                completion(response?.mapItems ?? [])
            }
        }
    }
    
    static func searchByName(_ query: String, near coordinate: CLLocationCoordinate2D, completion: @escaping ([MKMapItem]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
        
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                completion(response?.mapItems ?? [])
            }
        }
    }
}
