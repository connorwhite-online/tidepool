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

        // Home exclusion
        if let home = homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let visitCL = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
            if visitCL.distance(from: homeCL) < homeHideRadiusMeters { return }
        }

        let location = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        snapToPOI(location: location, arrivedAt: visit.arrivalDate, departedAt: visit.departureDate, confidence: 1.0, source: "visit")
    }

    // MARK: - Dwell Detection (secondary signal from didUpdateLocations)

    /// Call from LocationManager.didUpdateLocations to detect stationary dwell.
    func processLocationUpdate(_ location: CLLocation) {
        // Home exclusion
        if let home = homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            if location.distance(from: homeCL) < homeHideRadiusMeters {
                dwellLocation = nil
                dwellStart = nil
                return
            }
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
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self, let placemark = placemarks?.first else { return }

            let name = placemark.name ?? placemark.thoroughfare ?? "Unknown"
            let category = self.inferCategory(from: placemark)

            // Try MKLocalSearch to find the actual business
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = name
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: self.poiSearchRadiusMeters * 2,
                longitudinalMeters: self.poiSearchRadiusMeters * 2
            )

            MKLocalSearch(request: request).start { [weak self] response, _ in
                guard let self else { return }

                let bestMatch = response?.mapItems.first
                let resolvedName = bestMatch?.name ?? name
                let resolvedCategory = bestMatch.flatMap { PlaceCategory.from(mapItem: $0) } ?? category
                let resolvedCoord = bestMatch?.placemark.location?.coordinate ?? location.coordinate

                let calendar = Calendar.current
                let report = VisitReport(
                    poiId: bestMatch?.name.flatMap { FavoriteLocation.stablePlaceId(name: $0, coordinate: resolvedCoord) },
                    yelpId: nil,
                    name: resolvedName,
                    category: TidepoolShared.PlaceCategory(rawValue: resolvedCategory.rawValue) ?? .other,
                    latitude: resolvedCoord.latitude,
                    longitude: resolvedCoord.longitude,
                    arrivedAt: self.iso.string(from: arrivedAt),
                    departedAt: self.iso.string(from: departedAt),
                    dayOfWeek: calendar.component(.weekday, from: arrivedAt) - 1, // 0=Sun
                    hourOfDay: calendar.component(.hour, from: arrivedAt),
                    durationMinutes: Int(departedAt.timeIntervalSince(arrivedAt) / 60),
                    confidence: confidence,
                    source: source
                )

                self.pendingVisits.append(report)
                self.savePending()

                // Flush immediately — we may only have a few seconds of background time
                self.flushToServer()

                // Try Yelp match in background
                Task {
                    if let match = try? await BackendClient.shared.matchPlace(
                        name: resolvedName,
                        lat: resolvedCoord.latitude,
                        lng: resolvedCoord.longitude
                    ) {
                        // Update the last pending visit with yelp ID
                        if var last = self.pendingVisits.last, last.name == resolvedName {
                            self.pendingVisits.removeLast()
                            let updated = VisitReport(
                                poiId: last.poiId, yelpId: match.yelpID, name: last.name,
                                category: last.category, latitude: last.latitude, longitude: last.longitude,
                                arrivedAt: last.arrivedAt, departedAt: last.departedAt,
                                dayOfWeek: last.dayOfWeek, hourOfDay: last.hourOfDay,
                                durationMinutes: last.durationMinutes, confidence: last.confidence, source: last.source
                            )
                            self.pendingVisits.append(updated)
                            self.savePending()
                        }
                    }
                }
            }
        }
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
