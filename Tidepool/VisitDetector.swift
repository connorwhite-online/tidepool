import Foundation
import CoreLocation
import MapKit
import BackgroundTasks
import TidepoolShared

/// Detects real POI visits from CLVisit events and location dwell,
/// snaps them to actual businesses, and batch-uploads to the server.
@MainActor
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

    // Hidden-places cache so the exclusion check on every location update
    // doesn't UserDefaults-read + JSON-decode. Keyed by raw Data so any
    // write through @AppStorage invalidates it.
    private var hiddenPlacesCacheKey: Data?
    private var hiddenPlacesCache: [HiddenPlace] = []

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
    nonisolated func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskIdentifier, using: nil) { task in
            // BGTaskScheduler delivers callbacks on a private serial queue;
            // hop to main so the @MainActor-isolated handler can run.
            guard let bgTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handleBackgroundTask(bgTask)
            }
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
            await self.resolveAndRecord(
                location: location, arrivedAt: arrivedAt, departedAt: departedAt,
                confidence: confidence, source: source
            )
        }
    }

    private func resolveAndRecord(location: CLLocation, arrivedAt: Date, departedAt: Date, confidence: Float, source: String) async {
        let coord = location.coordinate

        // Strategy 1: MapKit POI search, scored by dwell-fit × distance.
        // This rejects transit stops, ATMs, parking, etc. that happen to be
        // physically closer than the actual business the user dwelled at.
        let mapKitTop = await POIScoring.scoredCandidates(near: coord, radius: poiSearchRadiusMeters).first

        // Strategy 2: Google Places match. The backend's matchPlace is a Google
        // Places query — its catalog is much better than MKLocalSearch for
        // "places people review/visit", so use it as confirmation or override.
        let googleSeedName = mapKitTop?.item.name ?? "place"
        let googleMatch: PlaceDetail? = try? await BackendClient.shared.matchPlace(
            name: googleSeedName,
            lat: coord.latitude,
            lng: coord.longitude
        )

        // Decide which source to trust.
        if let google = googleMatch,
           let g = google.coordinates {
            let gLoc = CLLocation(latitude: g.latitude, longitude: g.longitude)
            let gDistance = gLoc.distance(from: location)
            // Trust Google if it's within the search radius and either MapKit
            // agreed on the name or MapKit's pick was a low-dwell category.
            let mapKitWeak = (mapKitTop.map { POIScoring.dwellWeight(for: $0.item) } ?? 0) < 0.5
            let namesMatch = mapKitTop?.item.name?.lowercased() == google.name.lowercased()
            if gDistance <= poiSearchRadiusMeters && (namesMatch || mapKitWeak || mapKitTop == nil) {
                let category = PlaceCategory(rawValue: google.categories.first?.lowercased() ?? "") ?? Self.category(for: mapKitTop?.item)
                recordVisit(
                    name: google.name, category: category,
                    coordinate: CLLocationCoordinate2D(latitude: g.latitude, longitude: g.longitude),
                    arrivedAt: arrivedAt, departedAt: departedAt,
                    confidence: confidence, source: source,
                    yelpID: google.yelpID
                )
                return
            }
        }

        if let mk = mapKitTop, let name = mk.item.name {
            recordVisit(
                name: name,
                category: Self.category(for: mk.item),
                coordinate: mk.item.placemark.location?.coordinate ?? coord,
                arrivedAt: arrivedAt, departedAt: departedAt,
                confidence: confidence, source: source,
                yelpID: nil
            )
            return
        }

        // Strategy 3: Reverse geocode fallback.
        let placemark = await withCheckedContinuation { (cont: CheckedContinuation<CLPlacemark?, Never>) in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                cont.resume(returning: placemarks?.first)
            }
        }

        let geocodedName = placemark?.name ?? placemark?.thoroughfare ?? "Unknown location"
        let looksLikeAddress = geocodedName.first?.isNumber == true

        if !looksLikeAddress {
            let category = placemark.map { self.inferCategory(from: $0) } ?? .other
            recordVisit(
                name: geocodedName, category: category, coordinate: coord,
                arrivedAt: arrivedAt, departedAt: departedAt,
                confidence: confidence, source: source, yelpID: nil
            )
            return
        }

        // Last resort: address string.
        recordVisit(
            name: geocodedName, category: .other, coordinate: coord,
            arrivedAt: arrivedAt, departedAt: departedAt,
            confidence: confidence, source: source, yelpID: nil
        )
    }

    private static func category(for item: MKMapItem?) -> PlaceCategory {
        guard let item else { return .other }
        return PlaceCategory.from(mapItem: item)
    }

    private func recordVisit(name: String, category: PlaceCategory, coordinate: CLLocationCoordinate2D, arrivedAt: Date, departedAt: Date, confidence: Float, source: String, yelpID: String?) {
        let calendar = Calendar.current
        let poiId = FavoriteLocation.stablePlaceId(name: name, coordinate: coordinate)

        let report = VisitReport(
            poiId: poiId,
            yelpId: yelpID,
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

        guard reconcileOverlapping(report) else { return }
        appendDedupe(report)
        savePending()
        flushToServer()
    }

    /// Check if a location falls within any exclusion zone (home + hidden places).
    private func isInExclusionZone(_ location: CLLocation) -> Bool {
        if let home = homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            if location.distance(from: homeCL) < homeHideRadiusMeters { return true }
        }

        for place in hiddenPlaces() {
            let placeCL = CLLocation(latitude: place.latitude, longitude: place.longitude)
            if location.distance(from: placeCL) < homeHideRadiusMeters { return true }
        }

        return false
    }

    private func hiddenPlaces() -> [HiddenPlace] {
        let data = UserDefaults.standard.data(forKey: "hidden_places_data") ?? Data()
        if data == hiddenPlacesCacheKey { return hiddenPlacesCache }
        hiddenPlacesCacheKey = data
        hiddenPlacesCache = (try? JSONDecoder().decode([HiddenPlace].self, from: data)) ?? []
        return hiddenPlacesCache
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
                batch.forEach { self.appendDedupe($0) }
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
                batch.forEach { self.appendDedupe($0) }
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

    /// Update a specific pending visit (for re-linking to correct POI).
    func updateVisit(at index: Int, with visit: VisitReport) {
        guard index < pendingVisits.count else { return }
        pendingVisits[index] = visit
        savePending()
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

    // MARK: - Persistence (file-based, survives reinstalls via backup)

    private var visitFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("pending_visits.json")
    }

    private func savePending() {
        guard let data = try? JSONEncoder().encode(pendingVisits) else { return }
        try? data.write(to: visitFileURL, options: .atomic)
    }

    private func loadPending() {
        // Try file first
        if let data = try? Data(contentsOf: visitFileURL),
           let visits = try? JSONDecoder().decode([VisitReport].self, from: data) {
            pendingVisits = Self.deduped(visits)
            if pendingVisits.count != visits.count { savePending() }
            return
        }
        // Fall back to UserDefaults (migrate old data)
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let visits = try? JSONDecoder().decode([VisitReport].self, from: data) {
            pendingVisits = Self.deduped(visits)
            savePending() // migrate to file
            UserDefaults.standard.removeObject(forKey: storeKey) // clean up old
        }
    }

    /// Append a visit only if no existing pending visit shares the same
    /// (arrivedAt, name) tuple. The server dedupes too, but local dedup
    /// keeps the queue and UI honest.
    private func appendDedupe(_ visit: VisitReport) {
        if pendingVisits.contains(where: { $0.arrivedAt == visit.arrivedAt && $0.name == visit.name }) {
            return
        }
        pendingVisits.append(visit)
    }

    /// When two POIs are detected for what is really one visit (e.g. a
    /// transit-stop name snaps from a broad CLVisit while the user is
    /// actually inside the storefront 50m away), the time ranges overlap
    /// and one fully contains the other. The shorter range is the more
    /// specific snap (GPS settled, smaller uncertainty), so we keep that
    /// one and drop the wrapper.
    ///
    /// - Returns: `true` if `newReport` should be appended, `false` if it
    ///   should be discarded because an existing pending visit is more
    ///   specific.
    private func reconcileOverlapping(_ newReport: VisitReport) -> Bool {
        guard let newArrived = iso.date(from: newReport.arrivedAt),
              let newDeparted = iso.date(from: newReport.departedAt) else { return true }
        let newCoord = CLLocation(latitude: newReport.latitude, longitude: newReport.longitude)
        let differentPlaceMeters: CLLocationDistance = 50

        var indicesToDrop: [Int] = []

        for (idx, existing) in pendingVisits.enumerated() {
            guard let exArrived = iso.date(from: existing.arrivedAt),
                  let exDeparted = iso.date(from: existing.departedAt) else { continue }
            let exCoord = CLLocation(latitude: existing.latitude, longitude: existing.longitude)

            // Same physical place — leave alone, appendDedupe handles same-name dupes.
            guard exCoord.distance(from: newCoord) > differentPlaceMeters else { continue }

            let exContainsNew = exArrived <= newArrived && exDeparted >= newDeparted
            let newContainsEx = newArrived <= exArrived && newDeparted >= exDeparted

            if exContainsNew && !newContainsEx {
                // Existing wraps new — new is more specific. Drop existing, keep new.
                indicesToDrop.append(idx)
            } else if newContainsEx && !exContainsNew {
                // New wraps existing — existing is more specific. Discard new.
                print("[VisitDetector] dropping wrapper visit '\(newReport.name)' (kept '\(existing.name)')")
                return false
            }
            // Partial overlap (neither contains the other) is treated as two
            // genuine consecutive visits — leave both.
        }

        for idx in indicesToDrop.reversed() {
            let dropped = pendingVisits.remove(at: idx)
            print("[VisitDetector] dropping wrapper visit '\(dropped.name)' (kept '\(newReport.name)')")
        }
        return true
    }

    private static func deduped(_ visits: [VisitReport]) -> [VisitReport] {
        var seen = Set<String>()
        var out: [VisitReport] = []
        out.reserveCapacity(visits.count)
        for v in visits {
            let key = "\(v.arrivedAt)|\(v.name)"
            if seen.insert(key).inserted { out.append(v) }
        }
        return out
    }
}
