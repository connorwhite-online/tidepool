import Foundation
import CoreLocation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var latestLocation: CLLocation?
    @Published var homeLocation: CLLocationCoordinate2D? {
        didSet { persistHome() }
    }

    private let manager = CLLocationManager()
    private let homeKey = "home_location"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        loadHome()
    }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func requestAlwaysAuthorization() {
        // Only meaningful after When-In-Use has been granted
        manager.requestAlwaysAuthorization()
    }

    func setBackgroundUpdatesEnabled(_ enabled: Bool) {
        manager.allowsBackgroundLocationUpdates = enabled
        manager.pausesLocationUpdatesAutomatically = true
        if enabled {
            if manager.authorizationStatus == .authorizedAlways {
                manager.startMonitoringSignificantLocationChanges()
                manager.startMonitoringVisits()
            }
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
        }
    }

    func applyReducedAccuracy(_ reduced: Bool) {
        manager.desiredAccuracy = reduced ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
        manager.distanceFilter = reduced ? 50 : 10
    }

    func setHome(to coordinate: CLLocationCoordinate2D) {
        homeLocation = coordinate
    }

    private func loadHome() {
        if let data = UserDefaults.standard.data(forKey: homeKey),
           let decoded = try? JSONDecoder().decode([Double].self, from: data), decoded.count == 2 {
            homeLocation = CLLocationCoordinate2D(latitude: decoded[0], longitude: decoded[1])
        }
    }

    private func persistHome() {
        guard let home = homeLocation else { return }
        let arr = [home.latitude, home.longitude]
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: homeKey)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // Update latest location on visit events as a coarse signal
        let coord = visit.coordinate
        latestLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
    }
} 