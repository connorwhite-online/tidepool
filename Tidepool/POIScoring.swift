import Foundation
import MapKit
import CoreLocation

/// Shared scoring for "which POI did the user actually dwell at?".
///
/// MKLocalSearch will happily return parking garages, bus stops and ATMs
/// alongside the cafe the user is actually inside, with the transit/service
/// landmarks frequently scoring nearest because their official map points
/// sit on street centrelines. We score candidates by category × distance
/// so the storefront wins even when it's a few meters further than a
/// nearby transit pin.
enum POIScoring {
    struct Candidate {
        let item: MKMapItem
        let distance: CLLocationDistance
        let score: Double
    }

    /// 0.0–1.0 weight expressing how plausible a 5+ minute dwell is at this
    /// kind of place. Transit/parking/ATMs are near-zero; cafes/restaurants/
    /// stores/parks/gyms/hotels are full weight.
    static func dwellWeight(for item: MKMapItem) -> Double {
        guard let category = item.pointOfInterestCategory else { return 0.7 }
        switch category {
        case .cafe, .restaurant, .foodMarket,
             .nightlife,
             .store,
             .park, .beach, .nationalPark, .campground,
             .movieTheater, .theater, .museum,
             .fitnessCenter,
             .hotel,
             .school, .university, .library,
             .stadium, .amusementPark, .aquarium, .zoo, .marina,
             .hospital:
            return 1.0
        case .bank, .postOffice, .laundry, .pharmacy:
            return 0.5
        case .gasStation, .atm, .restroom, .evCharger, .parking,
             .airport, .publicTransport,
             .police, .fireStation:
            return 0.05
        default:
            return 0.7
        }
    }

    /// Query MKLocalPointsOfInterest near `coord`, score every named result,
    /// and return them sorted by score (highest first). Zero-score results
    /// are dropped.
    static func scoredCandidates(near coord: CLLocationCoordinate2D, radius: CLLocationDistance) async -> [Candidate] {
        let anchor = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return await withCheckedContinuation { (cont: CheckedContinuation<[Candidate], Never>) in
            let request = MKLocalPointsOfInterestRequest(center: coord, radius: radius)
            MKLocalSearch(request: request).start { response, _ in
                let scored: [Candidate] = (response?.mapItems ?? []).compactMap { item in
                    guard item.name != nil,
                          let d = item.placemark.location?.distance(from: anchor),
                          d <= radius else { return nil }
                    let weight = dwellWeight(for: item)
                    let proximity = max(0.0, 1.0 - d / radius)
                    return Candidate(item: item, distance: d, score: proximity * weight)
                }
                .filter { $0.score > 0 }
                .sorted { $0.score > $1.score }
                cont.resume(returning: scored)
            }
        }
    }
}
