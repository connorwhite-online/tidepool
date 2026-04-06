import Foundation
import Photos
import CoreLocation
import MapKit
import TidepoolShared

// MARK: - Photo Location Data Models

struct PhotoLocationCluster: Identifiable {
    let id = UUID()
    let centerCoordinate: CLLocationCoordinate2D
    let radius: Double // in meters
    let photoCount: Int
    let frequencyScore: Double // How often the user visits this location
    let timeSpentScore: Double // How much time they spend here (inferred from photo timestamps)
    let category: PlaceCategory
    let inferredName: String?
    let poiId: String?       // Stable place ID from resolved business
    let yelpId: String?      // Yelp business ID if matched
    let firstVisit: Date
    let lastVisit: Date

    var interestWeight: Double {
        // Combine frequency and time spent for overall interest score
        return (frequencyScore * 0.6) + (timeSpentScore * 0.4)
    }
}

struct PhotoLocationMetrics {
    let totalPhotos: Int
    let locationEnabledPhotos: Int
    let clusters: [PhotoLocationCluster]
    let dateRange: ClosedRange<Date>?
    let processingDate: Date
}

// MARK: - Photos Integration Manager

@MainActor
class PhotosIntegrationManager: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var metrics: PhotoLocationMetrics?
    @Published var isProcessing: Bool = false
    @Published var clusters: [PhotoLocationCluster] = []
    @Published var lastProcessed: Date?
    
    private let userDefaults = UserDefaults.standard
    private let enabledKey = "photos_integration_enabled"
    private let lastProcessedKey = "photos_last_processed"
    private let clustersKey = "photos_location_clusters"
    
    // Clustering parameters
    private let minClusterRadius: Double = 50.0 // 50 meters
    private let maxClusterRadius: Double = 500.0 // 500 meters
    private let minPhotosPerCluster: Int = 3
    private let maxClusters: Int = .max
    
    init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        isEnabled = userDefaults.bool(forKey: enabledKey)
        lastProcessed = userDefaults.object(forKey: lastProcessedKey) as? Date
        loadCachedClusters()
    }
    
    func requestPermission() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        
        if status == .authorized || status == .limited {
            isEnabled = true
            userDefaults.set(true, forKey: enabledKey)
            // Don't automatically start processing here - let the caller decide
        }
    }
    
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
        
        if enabled && (authorizationStatus == .authorized || authorizationStatus == .limited) {
            Task {
                await processPhotoLocations()
            }
        } else if !enabled {
            clearData()
        }
    }
    
    func refreshData() async {
        guard isEnabled, authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        await processPhotoLocations()
    }
    
    private func processPhotoLocations() async {
        isProcessing = true

        // Step 1: Fetch all geotagged photos (background thread)
        let photoLocations = await Task.detached(priority: .userInitiated) {
            await self.fetchPhotoLocationsBackground()
        }.value

        // Clear POI cache to get fresh results
        userDefaults.removeObject(forKey: poiCacheKey)

        // Step 2: Build frequency grid and find hotspots (deterministic, pure math)
        let hotspots = await Task.detached(priority: .userInitiated) {
            self.findHotspots(photoLocations, metersPerCell: 30, minPhotos: 3)
        }.value

        // Filter out likely-home hotspots (500+ photos = you live there)
        let filteredHotspots = hotspots.filter { $0.photos.count < 500 }
        print("[Photos] \(hotspots.count) hotspots found, \(hotspots.count - filteredHotspots.count) excluded as likely-home, resolving \(filteredHotspots.count)")

        // Step 3: Resolve hotspot names via MapKit (cached per coordinate)
        let finalClusters = await resolveHotspotsToPOIs(filteredHotspots)

        clusters = finalClusters
        lastProcessed = Date()
        userDefaults.set(lastProcessed, forKey: lastProcessedKey)

        metrics = PhotoLocationMetrics(
            totalPhotos: photoLocations.count,
            locationEnabledPhotos: photoLocations.count,
            clusters: finalClusters,
            dateRange: dateRangeFrom(photoLocations),
            processingDate: Date()
        )
        userDefaults.set(photoLocations.count, forKey: "photos_total_count")
        print("[Photos] Total geotagged: \(photoLocations.count), hotspots: \(hotspots.count), resolved: \(finalClusters.filter { $0.inferredName != nil }.count)")

        saveClusters()
        backfillVisitsFromClusters()
        isProcessing = false
    }

    // MARK: - Hotspot Detection (deterministic, pure math)

    private struct Hotspot {
        let centerLat: Double
        let centerLon: Double
        let photos: [PhotoLocation]
        let distinctDays: Int
    }

    /// Build frequency grid, find cells with enough photos, flood-fill merge adjacent cells.
    private nonisolated func findHotspots(_ photos: [PhotoLocation], metersPerCell: Double, minPhotos: Int) -> [Hotspot] {
        let latMeters = 111_000.0

        // Quantize photos to grid cells
        var cellPhotos: [String: [PhotoLocation]] = [:]
        var cellXY: [String: (Int, Int)] = [:]

        for photo in photos {
            let lonMeters = latMeters * cos(photo.coordinate.latitude * .pi / 180)
            let x = Int(floor(photo.coordinate.longitude * lonMeters / metersPerCell))
            let y = Int(floor(photo.coordinate.latitude * latMeters / metersPerCell))
            let key = "\(x)_\(y)"
            cellPhotos[key, default: []].append(photo)
            cellXY[key] = (x, y)
        }

        // Find hot cells (minPhotos threshold)
        let hotKeys = Set(cellPhotos.filter { $0.value.count >= minPhotos }.keys)

        // Flood-fill merge adjacent hot cells
        var visited = Set<String>()
        var hotspots: [Hotspot] = []

        for key in hotKeys where !visited.contains(key) {
            var queue = [key]
            var groupPhotos: [PhotoLocation] = []

            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard !visited.contains(current), hotKeys.contains(current) else { continue }
                visited.insert(current)
                groupPhotos.append(contentsOf: cellPhotos[current] ?? [])

                if let (x, y) = cellXY[current] {
                    for dx in -1...1 {
                        for dy in -1...1 {
                            if dx == 0 && dy == 0 { continue }
                            let nk = "\(x + dx)_\(y + dy)"
                            if hotKeys.contains(nk) && !visited.contains(nk) {
                                queue.append(nk)
                            }
                        }
                    }
                }
            }

            guard !groupPhotos.isEmpty else { continue }

            let avgLat = groupPhotos.reduce(0.0) { $0 + $1.coordinate.latitude } / Double(groupPhotos.count)
            let avgLon = groupPhotos.reduce(0.0) { $0 + $1.coordinate.longitude } / Double(groupPhotos.count)
            let distinctDays = Set(groupPhotos.map { Calendar.current.startOfDay(for: $0.timestamp) }).count

            hotspots.append(Hotspot(centerLat: avgLat, centerLon: avgLon, photos: groupPhotos, distinctDays: distinctDays))
        }

        return hotspots.sorted { $0.photos.count > $1.photos.count }
    }

    // MARK: - POI Resolution (cached per hotspot coordinate)

    private let poiCacheKey = "photo_poi_cache"

    private func resolveHotspotsToPOIs(_ hotspots: [Hotspot]) async -> [PhotoLocationCluster] {
        // Load cache
        var cache: [String: (name: String, category: String)] = [:]
        if let data = userDefaults.data(forKey: poiCacheKey),
           let cached = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for (key, vals) in cached where vals.count == 2 {
                cache[key] = (name: vals[0], category: vals[1])
            }
        }

        var results: [PhotoLocationCluster] = []

        for batchStart in stride(from: 0, to: hotspots.count, by: 10) {
            let batchEnd = min(batchStart + 10, hotspots.count)

            let batchResults = await withTaskGroup(of: PhotoLocationCluster?.self) { group in
                for hotspot in hotspots[batchStart..<batchEnd] {
                    group.addTask {
                        let cacheKey = String(format: "%.4f_%.4f", hotspot.centerLat, hotspot.centerLon)
                        let sortedDates = hotspot.photos.map { $0.timestamp }.sorted()
                        let first = sortedDates.first ?? Date()
                        let last = sortedDates.last ?? Date()
                        let coord = CLLocationCoordinate2D(latitude: hotspot.centerLat, longitude: hotspot.centerLon)

                        let frequencyScore = min(Double(hotspot.distinctDays) / 20.0, 1.0)
                        let spanYears = last.timeIntervalSince(first) / (365.25 * 86400)
                        let spanScore = hotspot.distinctDays > 1 ? min(spanYears / 5.0, 1.0) : 0.0

                        // Check cache
                        if let cached = cache[cacheKey] {
                            return PhotoLocationCluster(
                                centerCoordinate: coord, radius: 30,
                                photoCount: hotspot.photos.count,
                                frequencyScore: frequencyScore, timeSpentScore: spanScore,
                                category: PlaceCategory(rawValue: cached.category) ?? .other,
                                inferredName: cached.name,
                                poiId: FavoriteLocation.stablePlaceId(name: cached.name, coordinate: coord),
                                yelpId: nil, firstVisit: first, lastVisit: last
                            )
                        }

                        // POI search (100m radius)
                        let poi = await self.findNearestPOI(lat: hotspot.centerLat, lon: hotspot.centerLon, radiusMeters: 100)

                        return PhotoLocationCluster(
                            centerCoordinate: poi?.2 ?? coord, radius: 30,
                            photoCount: hotspot.photos.count,
                            frequencyScore: frequencyScore, timeSpentScore: spanScore,
                            category: poi?.1 ?? .other,
                            inferredName: poi?.0,
                            poiId: poi.flatMap { p in FavoriteLocation.stablePlaceId(name: p.0, coordinate: p.2) },
                            yelpId: nil, firstVisit: first, lastVisit: last
                        )
                    }
                }

                var batch: [PhotoLocationCluster] = []
                for await r in group { if let r { batch.append(r) } }
                return batch
            }

            results.append(contentsOf: batchResults)
            if batchEnd < hotspots.count {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms between batches
            }
        }

        // Update cache
        var newCache: [String: [String]] = [:]
        for cluster in results where cluster.inferredName != nil {
            let key = String(format: "%.4f_%.4f", cluster.centerCoordinate.latitude, cluster.centerCoordinate.longitude)
            newCache[key] = [cluster.inferredName!, cluster.category.rawValue]
        }
        if let data = try? JSONEncoder().encode(newCache) {
            userDefaults.set(data, forKey: poiCacheKey)
        }

        return results.sorted { $0.photoCount > $1.photoCount }
    }

    /// Multi-strategy POI resolution with logging.
    private func findNearestPOI(lat: Double, lon: Double, radiusMeters: Double) async -> (String, PlaceCategory, CLLocationCoordinate2D)? {
        let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let location = CLLocation(latitude: lat, longitude: lon)

        // Strategy 1: MKLocalSearch with empty query (returns ALL nearby businesses)
        let searchResult = await withCheckedContinuation { (continuation: CheckedContinuation<MKMapItem?, Never>) in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = ""
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: radiusMeters, longitudinalMeters: radiusMeters)
            MKLocalSearch(request: request).start { response, _ in
                let best = response?.mapItems
                    .filter { $0.name != nil && $0.placemark.location != nil }
                    .filter { $0.placemark.location!.distance(from: location) <= radiusMeters }
                    .sorted { ($0.placemark.location?.distance(from: location) ?? .infinity) < ($1.placemark.location?.distance(from: location) ?? .infinity) }
                    .first
                continuation.resume(returning: best)
            }
        }

        if let item = searchResult, let name = item.name {
            return (name, PlaceCategory.from(mapItem: item), item.placemark.location?.coordinate ?? center)
        }

        // Strategy 2: POI-specific search
        let poiResult = await withCheckedContinuation { (continuation: CheckedContinuation<MKMapItem?, Never>) in
            let request = MKLocalPointsOfInterestRequest(center: center, radius: radiusMeters)
            MKLocalSearch(request: request).start { response, _ in
                let best = response?.mapItems
                    .filter { $0.name != nil && $0.placemark.location != nil }
                    .filter { $0.placemark.location!.distance(from: location) <= radiusMeters }
                    .sorted { ($0.placemark.location?.distance(from: location) ?? .infinity) < ($1.placemark.location?.distance(from: location) ?? .infinity) }
                    .first
                continuation.resume(returning: best)
            }
        }

        if let item = poiResult, let name = item.name {
            return (name, PlaceCategory.from(mapItem: item), item.placemark.location?.coordinate ?? center)
        }

        // Strategy 3: Reverse geocode
        let geocodeResult = await withCheckedContinuation { (continuation: CheckedContinuation<CLPlacemark?, Never>) in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                continuation.resume(returning: placemarks?.first)
            }
        }

        if let placemark = geocodeResult, let name = placemark.name {
            let looksLikeAddress = name.first?.isNumber == true
            if !looksLikeAddress {
                let category = inferPlaceCategory(from: placemark)
                return (name, category, placemark.location?.coordinate ?? center)
            }
        }

        return nil
    }

    private func inferPlaceCategory(from placemark: CLPlacemark) -> PlaceCategory {
        let name = (placemark.name ?? "").lowercased()
        if name.contains("park") || name.contains("trail") || name.contains("beach") { return .park }
        if name.contains("coffee") || name.contains("cafe") { return .cafe }
        if name.contains("restaurant") || name.contains("food") { return .restaurant }
        if name.contains("gym") || name.contains("fitness") { return .gym }
        if name.contains("bar") || name.contains("pub") { return .bar }
        if name.contains("mall") || name.contains("shop") { return .shopping }
        if name.contains("school") || name.contains("university") { return .school }
        if name.contains("hospital") { return .hospital }
        return .other
    }

    /// Fetch photo locations on a background thread (no main actor).
    private nonisolated func fetchPhotoLocationsBackground() async -> [PhotoLocation] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = false

        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        var photoLocations: [PhotoLocation] = []

        assets.enumerateObjects { asset, _, _ in
            guard let location = asset.location else { return }
            photoLocations.append(PhotoLocation(
                coordinate: location.coordinate,
                timestamp: asset.creationDate ?? Date(),
                asset: asset
            ))
        }

        return photoLocations
    }

    /// Cluster locations synchronously (pure computation, no UI).
    private nonisolated func clusterLocationsSync(_ locations: [PhotoLocation]) -> [PhotoLocationCluster] {
        guard !locations.isEmpty else { return [] }

        let sortedLocations = locations.sorted { $0.timestamp < $1.timestamp }
        var clusters: [LocationClusterBuilder] = []

        for location in sortedLocations {
            var addedToCluster = false
            for cluster in clusters {
                if cluster.canAdd(location, maxRadius: maxClusterRadius) {
                    cluster.add(location)
                    addedToCluster = true
                    break
                }
            }
            if !addedToCluster {
                clusters.append(LocationClusterBuilder(initialLocation: location))
            }
        }

        return clusters
            .filter { $0.locations.count >= minPhotosPerCluster }
            .sorted { $0.interestScore > $1.interestScore }
            .prefix(maxClusters)
            .map { $0.toPhotoLocationCluster() }
    }
    
    private func fetchPhotoLocations() async -> [PhotoLocation] {
        return await withCheckedContinuation { continuation in
            let fetchOptions = PHFetchOptions()
            fetchOptions.includeHiddenAssets = false
            
            let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            var photoLocations: [PhotoLocation] = []
            
            assets.enumerateObjects { asset, _, _ in
                guard let location = asset.location else { return }
                
                let photoLocation = PhotoLocation(
                    coordinate: location.coordinate,
                    timestamp: asset.creationDate ?? Date(),
                    asset: asset
                )
                photoLocations.append(photoLocation)
            }
            
            continuation.resume(returning: photoLocations)
        }
    }
    
    private func clusterLocations(_ locations: [PhotoLocation]) async -> [PhotoLocationCluster] {
        guard !locations.isEmpty else { return [] }
        
        // Sort by timestamp for temporal analysis
        let sortedLocations = locations.sorted { $0.timestamp < $1.timestamp }
        var clusters: [LocationClusterBuilder] = []
        
        for location in sortedLocations {
            var addedToCluster = false
            
            // Try to add to existing cluster
            for cluster in clusters {
                if cluster.canAdd(location, maxRadius: maxClusterRadius) {
                    cluster.add(location)
                    addedToCluster = true
                    break
                }
            }
            
            // Create new cluster if needed
            if !addedToCluster {
                let newCluster = LocationClusterBuilder(initialLocation: location)
                clusters.append(newCluster)
            }
        }
        
        // Filter and convert to final clusters
        return clusters
            .filter { $0.locations.count >= minPhotosPerCluster }
            .sorted { $0.interestScore > $1.interestScore }
            .prefix(maxClusters)
            .map { $0.toPhotoLocationCluster() }
    }
    
    private func enhanceClustersWithPlaceData(_ clusters: [PhotoLocationCluster]) async -> [PhotoLocationCluster] {
        // Process clusters concurrently (up to 5 at a time to avoid geocoder rate limits)
        return await withTaskGroup(of: (Int, PhotoLocationCluster).self) { group in
            for (i, cluster) in clusters.enumerated() {
                group.addTask {
                    let enhanced = await self.enhanceClusterWithPlaceInfo(cluster)
                    return (i, enhanced)
                }
            }
            var results = [(Int, PhotoLocationCluster)]()
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
    private func enhanceClusterWithPlaceInfo(_ cluster: PhotoLocationCluster) async -> PhotoLocationCluster {
        let location = CLLocation(latitude: cluster.centerCoordinate.latitude, longitude: cluster.centerCoordinate.longitude)

        // Step 1: Reverse geocode
        let placemark = await withCheckedContinuation { (continuation: CheckedContinuation<CLPlacemark?, Never>) in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                continuation.resume(returning: placemarks?.first)
            }
        }

        let geocodedName = placemark.flatMap { generatePlaceName(from: $0) }
        let geocodedCategory = placemark.map { inferPlaceCategory(from: $0) } ?? .other

        // Step 2: MKLocalSearch to find actual business
        let searchName = geocodedName ?? "place"
        let searchResult = await withCheckedContinuation { (continuation: CheckedContinuation<MKMapItem?, Never>) in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = searchName
            request.region = MKCoordinateRegion(
                center: cluster.centerCoordinate,
                latitudinalMeters: 200,
                longitudinalMeters: 200
            )
            MKLocalSearch(request: request).start { response, _ in
                // Pick closest match within 100m
                let best = response?.mapItems.first { item in
                    guard let itemLoc = item.placemark.location else { return false }
                    return itemLoc.distance(from: location) < 100
                }
                continuation.resume(returning: best ?? response?.mapItems.first)
            }
        }

        let resolvedName = searchResult?.name ?? geocodedName
        let resolvedCategory = searchResult.flatMap { PlaceCategory.from(mapItem: $0) } ?? geocodedCategory
        let resolvedCoord = searchResult?.placemark.location?.coordinate ?? cluster.centerCoordinate
        let poiId = resolvedName.map { FavoriteLocation.stablePlaceId(name: $0, coordinate: resolvedCoord) }

        // Step 3: Try Yelp match (best-effort)
        var yelpId: String? = nil
        if let name = resolvedName {
            yelpId = try? await BackendClient.shared.matchPlace(
                name: name, lat: resolvedCoord.latitude, lng: resolvedCoord.longitude
            ).yelpID
        }

        return PhotoLocationCluster(
            centerCoordinate: resolvedCoord,
            radius: cluster.radius,
            photoCount: cluster.photoCount,
            frequencyScore: cluster.frequencyScore,
            timeSpentScore: cluster.timeSpentScore,
            category: resolvedCategory,
            inferredName: resolvedName,
            poiId: poiId,
            yelpId: yelpId,
            firstVisit: cluster.firstVisit,
            lastVisit: cluster.lastVisit
        )
    }
    
    // inferPlaceCategory is defined above in the POI resolution section
    
    private func generatePlaceName(from placemark: CLPlacemark) -> String? {
        if let name = placemark.name, !name.isEmpty {
            return name
        }
        
        // Generate a descriptive name from address components
        var nameComponents: [String] = []
        
        if let thoroughfare = placemark.thoroughfare {
            nameComponents.append(thoroughfare)
        }
        
        if let locality = placemark.locality {
            nameComponents.append(locality)
        }
        
        return nameComponents.isEmpty ? nil : nameComponents.joined(separator: ", ")
    }
    
    private func dateRangeFrom(_ locations: [PhotoLocation]) -> ClosedRange<Date>? {
        guard !locations.isEmpty else { return nil }
        let dates = locations.map { $0.timestamp }.sorted()
        return dates.first!...dates.last!
    }
    
    func getInterestTags() -> [String: Int] {
        var tagCounts: [String: Int] = [:]
        
        for cluster in clusters {
            let weight = max(1, Int(cluster.interestWeight * 10)) // Scale to reasonable integers
            for tag in cluster.category.interestTags {
                tagCounts[tag, default: 0] += weight
            }
        }
        
        return tagCounts
    }
    
    // MARK: - Visit Backfill from Photo Clusters

    private let backfilledKey = "photo_clusters_backfilled"

    private func backfillVisitsFromClusters() {
        let backfilled = Set(UserDefaults.standard.stringArray(forKey: backfilledKey) ?? [])
        let iso = ISO8601DateFormatter()
        var newBackfilled = backfilled
        var visits: [VisitReport] = []

        for cluster in clusters {
            let clusterKey = "\(cluster.centerCoordinate.latitude)_\(cluster.centerCoordinate.longitude)"
            guard !backfilled.contains(clusterKey) else { continue }
            guard cluster.category != .home else { continue }

            let sharedCategory = TidepoolShared.PlaceCategory(rawValue: cluster.category.rawValue) ?? .other
            let calendar = Calendar.current

            let report = VisitReport(
                poiId: cluster.poiId,
                yelpId: cluster.yelpId,
                name: cluster.inferredName ?? "Photo location",
                category: sharedCategory,
                latitude: cluster.centerCoordinate.latitude,
                longitude: cluster.centerCoordinate.longitude,
                arrivedAt: iso.string(from: cluster.firstVisit),
                departedAt: iso.string(from: cluster.lastVisit),
                dayOfWeek: calendar.component(.weekday, from: cluster.firstVisit) - 1,
                hourOfDay: calendar.component(.hour, from: cluster.firstVisit),
                durationMinutes: Int(cluster.lastVisit.timeIntervalSince(cluster.firstVisit) / 60),
                confidence: 0.5,
                source: "photo"
            )
            visits.append(report)
            newBackfilled.insert(clusterKey)
        }

        guard !visits.isEmpty else { return }
        UserDefaults.standard.set(Array(newBackfilled), forKey: backfilledKey)

        Task { @MainActor in
            guard BackendClient.shared.isAuthenticated else { return }
            do {
                let response = try await BackendClient.shared.uploadVisits(VisitBatchRequest(visits: visits))
                print("[PhotosIntegration] backfilled \(response.accepted) visits from photo clusters")
            } catch {
                print("[PhotosIntegration] backfill failed: \(error.localizedDescription)")
            }
        }
    }

    private func saveClusters() {
        guard let data = try? JSONEncoder().encode(clusters) else { return }
        userDefaults.set(data, forKey: clustersKey)
    }
    
    private func loadCachedClusters() {
        guard let data = userDefaults.data(forKey: clustersKey),
              let savedClusters = try? JSONDecoder().decode([PhotoLocationCluster].self, from: data) else {
            return
        }
        clusters = savedClusters
    }
    
    private func clearData() {
        clusters = []
        metrics = nil
        lastProcessed = nil
        userDefaults.removeObject(forKey: lastProcessedKey)
        userDefaults.removeObject(forKey: clustersKey)
    }
    
    /// Get a summary of discovered places for display
    func getPlacesSummary() -> String? {
        guard !clusters.isEmpty else { return nil }

        let photoCount = metrics?.totalPhotos ?? userDefaults.integer(forKey: "photos_total_count")
        let geotagged = metrics?.locationEnabledPhotos ?? clusters.reduce(0) { $0 + $1.photoCount }
        let nonHome = clusters.filter { $0.category != .home }
        let namedCount = nonHome.filter { InterestVectorManager.isLegitPlaceName($0) }.count

        let photoStr = photoCount > 1000 ? "\(photoCount / 1000)k" : "\(photoCount)"
        if namedCount > 0 {
            return "\(photoStr) scanned · \(namedCount) places identified"
        } else {
            return "\(photoStr) scanned · \(nonHome.count) locations"
        }
    }
}

// MARK: - Helper Classes

private struct PhotoLocation {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let asset: PHAsset
}

private class LocationClusterBuilder {
    var locations: [PhotoLocation] = []
    var centerCoordinate: CLLocationCoordinate2D
    
    init(initialLocation: PhotoLocation) {
        self.locations = [initialLocation]
        self.centerCoordinate = initialLocation.coordinate
    }
    
    func canAdd(_ location: PhotoLocation, maxRadius: Double) -> Bool {
        let distance = CLLocation(latitude: centerCoordinate.latitude, longitude: centerCoordinate.longitude)
            .distance(from: CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
        return distance <= maxRadius
    }
    
    func add(_ location: PhotoLocation) {
        locations.append(location)
        updateCenter()
    }
    
    private func updateCenter() {
        let totalLat = locations.map { $0.coordinate.latitude }.reduce(0, +)
        let totalLng = locations.map { $0.coordinate.longitude }.reduce(0, +)
        let count = Double(locations.count)
        
        centerCoordinate = CLLocationCoordinate2D(
            latitude: totalLat / count,
            longitude: totalLng / count
        )
    }
    
    var interestScore: Double {
        let photoCount = Double(locations.count)
        let timeSpan = timeSpanDays
        let frequency = photoCount / max(timeSpan, 1.0)
        
        // Score based on frequency and total photos
        return frequency * log(photoCount + 1)
    }
    
    private var timeSpanDays: Double {
        guard locations.count > 1 else { return 1.0 }
        let timestamps = locations.map { $0.timestamp }.sorted()
        let span = timestamps.last!.timeIntervalSince(timestamps.first!)
        return max(span / (24 * 60 * 60), 1.0) // Convert to days, minimum 1 day
    }
    
    func toPhotoLocationCluster() -> PhotoLocationCluster {
        let timestamps = locations.map { $0.timestamp }.sorted()
        let radius = calculateRadius()
        
        return PhotoLocationCluster(
            centerCoordinate: centerCoordinate,
            radius: radius,
            photoCount: locations.count,
            frequencyScore: calculateFrequencyScore(),
            timeSpentScore: calculateTimeSpentScore(),
            category: .other, // Will be enhanced later
            inferredName: nil, // Will be enhanced later
            poiId: nil,
            yelpId: nil,
            firstVisit: timestamps.first ?? Date(),
            lastVisit: timestamps.last ?? Date()
        )
    }
    
    private func calculateRadius() -> Double {
        guard locations.count > 1 else { return 50.0 }
        
        let center = CLLocation(latitude: centerCoordinate.latitude, longitude: centerCoordinate.longitude)
        let distances = locations.map { location in
            center.distance(from: CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
        }
        
        return distances.max() ?? 50.0
    }
    
    private func calculateFrequencyScore() -> Double {
        let photoCount = Double(locations.count)
        return min(photoCount / 50.0, 1.0) // Normalize to 0-1 scale
    }
    
    private func calculateTimeSpentScore() -> Double {
        // Infer time spent based on photo density and time clustering
        let timeSpan = timeSpanDays
        let photoCount = Double(locations.count)
        
        // More photos in shorter time span suggests more time spent there
        let density = photoCount / timeSpan
        return min(density / 10.0, 1.0) // Normalize to 0-1 scale
    }
}

// MARK: - PhotoLocationCluster Extensions

extension PhotoLocationCluster: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension PhotoLocationCluster: Equatable {
    static func == (lhs: PhotoLocationCluster, rhs: PhotoLocationCluster) -> Bool {
        return lhs.id == rhs.id
    }
}

extension PhotoLocationCluster: Codable {
    enum CodingKeys: String, CodingKey {
        case centerCoordinate, radius, photoCount, frequencyScore, timeSpentScore
        case category, inferredName, poiId, yelpId, firstVisit, lastVisit
        case latitude, longitude
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        centerCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        
        radius = try container.decode(Double.self, forKey: .radius)
        photoCount = try container.decode(Int.self, forKey: .photoCount)
        frequencyScore = try container.decode(Double.self, forKey: .frequencyScore)
        timeSpentScore = try container.decode(Double.self, forKey: .timeSpentScore)
        category = try container.decode(PlaceCategory.self, forKey: .category)
        inferredName = try container.decodeIfPresent(String.self, forKey: .inferredName)
        poiId = try container.decodeIfPresent(String.self, forKey: .poiId)
        yelpId = try container.decodeIfPresent(String.self, forKey: .yelpId)
        firstVisit = try container.decode(Date.self, forKey: .firstVisit)
        lastVisit = try container.decode(Date.self, forKey: .lastVisit)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(centerCoordinate.latitude, forKey: .latitude)
        try container.encode(centerCoordinate.longitude, forKey: .longitude)
        try container.encode(radius, forKey: .radius)
        try container.encode(photoCount, forKey: .photoCount)
        try container.encode(frequencyScore, forKey: .frequencyScore)
        try container.encode(timeSpentScore, forKey: .timeSpentScore)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(inferredName, forKey: .inferredName)
        try container.encodeIfPresent(poiId, forKey: .poiId)
        try container.encodeIfPresent(yelpId, forKey: .yelpId)
        try container.encode(firstVisit, forKey: .firstVisit)
        try container.encode(lastVisit, forKey: .lastVisit)
    }
}
