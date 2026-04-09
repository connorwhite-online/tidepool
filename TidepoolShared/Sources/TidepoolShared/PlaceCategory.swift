import Foundation

/// Place categories shared between client and server.
/// The iOS client extends this with MapKit-specific functionality (iconName, from(mapItem:)).
public enum PlaceCategory: String, Codable, CaseIterable, Sendable {
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

    public var displayName: String {
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

    /// Interest tags for the recommendation/vector system
    public var interestTags: [String] {
        switch self {
        case .restaurant, .fineDining:
            return ["dining", "restaurant", "social"]
        case .cafe:
            return ["coffee", "cafe", "social", "work"]
        case .bar, .nightclub:
            return ["nightlife", "bar", "social", "entertainment"]
        case .fastFood:
            return ["fast_food", "dining"]
        case .bakery:
            return ["bakery", "coffee", "casual"]
        case .movie:
            return ["movies", "entertainment", "social"]
        case .park, .beach, .hiking:
            return ["outdoor", "nature", "fitness"]
        case .gym:
            return ["fitness", "gym", "workout"]
        case .museum:
            return ["culture", "arts", "museum"]
        case .theater:
            return ["culture", "entertainment", "arts", "social"]
        case .shopping, .mall:
            return ["shopping", "mall", "social"]
        case .bookstore:
            return ["bookstore", "culture", "quiet"]
        case .library:
            return ["bookstore", "study", "quiet"]
        case .grocery:
            return ["grocery", "daily"]
        default:
            return []
        }
    }
}
