import Foundation
import CoreLocation
import MapKit
import BackgroundTasks
import TidepoolShared

/// Detects real POI visits from CLVisit events and location dwell,
/// snaps them to actual businesses, and batch-uploads to the server.
final class VisitDetector: NSObject {
    static let shared = VisitDetector()

    private let minDwellSeconds: TimeInterval = 300 // 5 minutes
    private let homeHideRadiusMeters: CLLocationDistance = 152.4 // 500 ft
    private let poiSearchRadiusMeters: CLLocationDistance = 100
    private let batchUploadInterval: TimeInterval = 900 // 15 minutes
    private let storeKey = "pending_visits"

    private(set) var pendingVisits: [VisitReport] = []
    private(set) var lastUploadError: String?
    private(set) var lastUploadDate: Date?
    private var uploadTimer: Timer?
    private var homeLocation: CLLocationCoordinate2D?

    // Dwell detection state
    private var dwellLocation: CLLocation?
    private var dwellStart: Date?

    private let iso = ISO8601DateFormatter()

    static let bgTaskIdentifier = "studio.connorwhite.Tidepool.visitUpload"

    override init() {
        super.init()
        loadPending()
        // Load home location from UserDefaults at init
        if let data = UserDefaults.standard.data(forKey: "home_location"),
           let coords = try? JSONDecoder().decode([Double].self, from: data), coords.count == 2 {
            homeLocation = CLLocationCoordinate2D(latitude: coords[0], longitude: coords[1])
        }
    }

    // MARK: - Background Task Scheduling

    /// Register the background task handler. Call once at app launch.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskIdentifier, using: nil) { task in
            self.handleBackgroundTask(task as! BGProcessingTask)
        }
    }

    /// Schedule the next background upload. Call after each flush or on app background.
    func scheduleBackgroundUpload() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[VisitDetector] bg task scheduling failed: \(error.localizedDescription)")
        }
    }

    private func handleBackgroundTask(_ task: BGProcessingTask) {
        // Schedule the next one
        scheduleBackgroundUpload()

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        flushToServer()

        // Give the upload a moment then mark complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            task.setTaskCompleted(success: true)
        }
    }

    /// Called when the app comes to foreground or periodically.
    func startBatchUploads() {
        uploadTimer?.invalidate()
        uploadTimer = Timer.scheduledTimer(withTimeInterval: batchUploadInterval, repeats: true) { [weak self] _ in
            self?.flushToServer()
        }
        // Also flush immediately on start
        flushToServer()
    }

    func stopBatchUploads() {
        uploadTimer?.invalidate()
        uploadTimer = nil
    }

    func updateHomeLocation(_ home: CLLocationCoordinate2D?) {
        homeLocation = home
    }

    // MARK: - CLVisit Processing

    /// Process a CLVisit event from LocationManager.
    func processVisit(_ visit: CLVisit) {
        // Skip ongoing visits
        guard visit.departureDate != .distantFuture else { return }

        // Skip bogus dates (iOS sometimes returns .distantPast for arrival)
        guard visit.arrivalDate.timeIntervalSince1970 > 946684800 else { return } // after year 2000

        let duration = visit.departureDate.timeIntervalSince(visit.arrivalDate)
        guard duration >= minDwellSeconds else { return }
        guard duration < 86400 else { return } // skip visits longer than 24 hours (bogus)

        // Home + hidden places exclusion
        let visitCL = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        if isInExclusionZone(visitCL) { return }

        snapToPOI(location: visitCL, arrivedAt: visit.arrivalDate, departedAt: visit.departureDate, confidence: 1.0, source: "visit")
    }

    // MARK: - Dwell Detection (secondary signal from didUpdateLocations)

    /// Call from LocationManager.didUpdateLocations to detect stationary dwell.
    func processLocationUpdate(_ location: CLLocation) {
        if isInExclusionZone(location) {
            dwellLocation = nil
            dwellStart = nil
            return
        }

        if let dwellLoc = dwellLocation, let start = dwellStart {
            let distance = location.distance(from: dwellLoc)
            if distance < 50 {
                // Still dwelling — check if threshold met
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= minDwellSeconds {
                    snapToPOI(location: dwellLoc, arrivedAt: start, departedAt: Date(), confidence: 0.8, source: "visit")
                    // Reset to avoid duplicate detections
                    dwellLocation = location
                    dwellStart = Date()
                }
            } else {
                // Moved away — reset dwell
                dwellLocation = location
                dwellStart = Date()
            }
        } else {
            dwellLocation = location
            dwellStart = Date()
        }
    }

    // MARK: - POI Snapping

    private func snapToPOI(location: CLLocation, arrivedAt: Date, departedAt: Date, confidence: Float, source: String) {
        Task {
            let coord = location.coordinate

            // Strategy 1: Reverse geocode to get a name, then try Foursquare match via server
            let placemark = await withCheckedContinuation { (cont: CheckedContinuation<CLPlacemark?, Never>) in
                CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                    cont.resume(returning: placemarks?.first)
                }
            }

            let geocodedName = placemark?.name ?? placemark?.thoroughfare ?? "Unknown location"
            let looksLikeAddress = geocodedName.first?.isNumber == true

            // Strategy 2: Try Foursquare via backend (best database)
            if let detail = try? await BackendClient.shared.matchPlace(
                name: looksLikeAddress ? "restaurant" : geocodedName,
                lat: coord.latitude,
                lng: coord.longitude
            ) {
                // Verify the Foursquare match is reasonably close
                if let fsqCoord = detail.coordinates {
                    let fsqLoc = CLLocation(latitude: fsqCoord.latitude, longitude: fsqCoord.longitude)
                    let distance = fsqLoc.distance(from: location)
                    if distance < 150 {
                        let category = PlaceCategory(rawValue: detail.categories.first?.lowercased() ?? "") ?? .restaurant
                        self.recordVisit(
                            name: detail.name,
                            category: category,
                            coordinate: CLLocationCoordinate2D(latitude: fsqCoord.latitude, longitude: fsqCoord.longitude),
                            arrivedAt: arrivedAt, departedAt: departedAt,
                            confidence: confidence, source: source
                        )
                        return
                    }
                }
            }

            // Strategy 3: MapKit POI search as fallback
            let poiResult = await withCheckedContinuation { (cont: CheckedContinuation<MKMapItem?, Never>) in
                let request = MKLocalPointsOfInterestRequest(center: coord, radius: self.poiSearchRadiusMeters)
                MKLocalSearch(request: request).start { response, _ in
                    let best = response?.mapItems
                        .filter { $0.placemark.location?.distance(from: location) ?? .infinity < self.poiSearchRadiusMeters }
                        .sorted { ($0.placemark.location?.distance(from: location) ?? .infinity) < ($1.placemark.location?.distance(from: location) ?? .infinity) }
                        .first
                    cont.resume(returning: best)
                }
            }

            if let poi = poiResult, let name = poi.name {
                self.recordVisit(
                    name: name,
                    category: PlaceCategory.from(mapItem: poi),
                    coordinate: poi.placemark.location?.coordinate ?? coord,
                    arrivedAt: arrivedAt, departedAt: departedAt,
                    confidence: confidence, source: source
                )
                return
            }

            // Strategy 4: Use geocoded name if it's not just an address
            if !looksLikeAddress {
                let category = placemark.map { self.inferCategory(from: $0) } ?? .other
                self.recordVisit(name: geocodedName, category: category, coordinate: coord,
                                 arrivedAt: arrivedAt, departedAt: departedAt, confidence: confidence, source: source)
            } else {
                // Last resort: record with address
                self.recordVisit(name: geocodedName, category: .other, coordinate: coord,
                                 arrivedAt: arrivedAt, departedAt: departedAt, confidence: confidence, source: source)
            }
        }
    }

    private func recordVisit(name: String, category: PlaceCategory, coordinate: CLLocationCoordinate2D, arrivedAt: Date, departedAt: Date, confidence: Float, source: String) {
        let calendar = Calendar.current
        let poiId = FavoriteLocation.stablePlaceId(name: name, coordinate: coordinate)

        let report = VisitReport(
            poiId: poiId,
            yelpId: nil,
            name: name,
            category: TidepoolShared.PlaceCategory(rawValue: category.rawValue) ?? .other,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            arrivedAt: iso.string(from: arrivedAt),
            departedAt: iso.string(from: departedAt),
            dayOfWeek: calendar.component(.weekday, from: arrivedAt) - 1,
            hourOfDay: calendar.component(.hour, from: arrivedAt),
            durationMinutes: Int(departedAt.timeIntervalSince(arrivedAt) / 60),
            confidence: confidence,
            source: source
        )

        pendingVisits.append(report)
        savePending()
        flushToServer()

        // Try Yelp match in background
        Task {
            if let match = try? await BackendClient.shared.matchPlace(
                name: name, lat: coordinate.latitude, lng: coordinate.longitude
            ) {
                if let idx = self.pendingVisits.lastIndex(where: { $0.name == name && $0.yelpId == nil }) {
                    let old = self.pendingVisits[idx]
                    self.pendingVisits[idx] = VisitReport(
                        poiId: old.poiId, yelpId: match.yelpID, name: old.name,
                        category: old.category, latitude: old.latitude, longitude: old.longitude,
                        arrivedAt: old.arrivedAt, departedAt: old.departedAt,
                        dayOfWeek: old.dayOfWeek, hourOfDay: old.hourOfDay,
                        durationMinutes: old.durationMinutes, confidence: old.confidence, source: old.source
                    )
                    self.savePending()
                }
            }
        }
    }

    /// Check if a location falls within any exclusion zone (home + hidden places).
    private func isInExclusionZone(_ location: CLLocation) -> Bool {
        // Home check
        if let home = homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            if location.distance(from: homeCL) < homeHideRadiusMeters { return true }
        }

        // Hidden places check
        if let data = UserDefaults.standard.data(forKey: "hidden_places_data"),
           let places = try? JSONDecoder().decode([HiddenPlace].self, from: data) {
            for place in places {
                let placeCL = CLLocation(latitude: place.latitude, longitude: place.longitude)
                if location.distance(from: placeCL) < homeHideRadiusMeters { return true }
            }
        }

        return false
    }

    private func inferCategory(from placemark: CLPlacemark) -> PlaceCategory {
        let name = (placemark.name ?? "").lowercased()
        if name.contains("park") || name.contains("trail") || name.contains("beach") { return .park }
        if name.contains("coffee") || name.contains("cafe") { return .cafe }
        if name.contains("restaurant") || name.contains("food") { return .restaurant }
        if name.contains("gym") || name.contains("fitness") { return .gym }
        if name.contains("bar") || name.contains("pub") { return .bar }
        if name.contains("mall") || name.contains("shop") { return .shopping }
        return .other
    }

    // MARK: - Batch Upload

    private func flushToServer() {
        guard !pendingVisits.isEmpty else { return }

        let batch = pendingVisits
        pendingVisits = []
        savePending()

        Task { @MainActor in
            guard BackendClient.shared.isAuthenticated else {
                self.pendingVisits.append(contentsOf: batch)
                self.savePending()
                self.lastUploadError = "Not authenticated"
                return
            }
            do {
                let response = try await BackendClient.shared.uploadVisits(VisitBatchRequest(visits: batch))
                self.lastUploadDate = Date()
                self.lastUploadError = nil
                print("[VisitDetector] uploaded \(response.accepted) visits, \(response.duplicates) duplicates")
            } catch {
                self.pendingVisits.append(contentsOf: batch)
                self.savePending()
                self.lastUploadError = error.localizedDescription
                print("[VisitDetector] upload failed, re-queued: \(error.localizedDescription)")
            }
        }
    }

    /// Manually retry flushing pending visits.
    func retryUpload() {
        flushToServer()
    }

    /// Remove a specific pending visit by index.
    func removeVisit(at index: Int) {
        guard index < pendingVisits.count else { return }
        pendingVisits.remove(at: index)
        savePending()
    }

    /// Clear all pending visits.
    func clearPending() {
        pendingVisits = []
        savePending()
        lastUploadError = nil
    }

    // MARK: - Persistence

    private func savePending() {
        guard let data = try? JSONEncoder().encode(pendingVisits) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func loadPending() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let visits = try? JSONDecoder().decode([VisitReport].self, from: data) else { return }
        pendingVisits = visits
    }
}
