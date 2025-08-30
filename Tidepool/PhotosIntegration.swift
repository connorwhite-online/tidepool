import Foundation
import Photos
import CoreLocation
import MapKit

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
    private let maxClusters: Int = 50
    
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
        
        let photoLocations = await fetchPhotoLocations()
        let newClusters = await clusterLocations(photoLocations)
        let enhancedClusters = await enhanceClustersWithPlaceData(newClusters)
        
        clusters = enhancedClusters
        lastProcessed = Date()
        userDefaults.set(lastProcessed, forKey: lastProcessedKey)
        
        metrics = PhotoLocationMetrics(
            totalPhotos: photoLocations.count,
            locationEnabledPhotos: photoLocations.count,
            clusters: enhancedClusters,
            dateRange: dateRangeFrom(photoLocations),
            processingDate: Date()
        )
        
        saveClusters()
        isProcessing = false
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
        var enhancedClusters: [PhotoLocationCluster] = []
        
        for cluster in clusters {
            let enhancedCluster = await enhanceClusterWithPlaceInfo(cluster)
            enhancedClusters.append(enhancedCluster)
        }
        
        return enhancedClusters
    }
    
    private func enhanceClusterWithPlaceInfo(_ cluster: PhotoLocationCluster) async -> PhotoLocationCluster {
        return await withCheckedContinuation { continuation in
            let geocoder = CLGeocoder()
            let location = CLLocation(latitude: cluster.centerCoordinate.latitude, longitude: cluster.centerCoordinate.longitude)
            
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                var enhancedCluster = cluster
                
                if let placemark = placemarks?.first {
                    // Try to infer place type from placemark
                    let inferredCategory = self.inferPlaceCategory(from: placemark)
                    let inferredName = self.generatePlaceName(from: placemark)
                    
                    enhancedCluster = PhotoLocationCluster(
                        centerCoordinate: cluster.centerCoordinate,
                        radius: cluster.radius,
                        photoCount: cluster.photoCount,
                        frequencyScore: cluster.frequencyScore,
                        timeSpentScore: cluster.timeSpentScore,
                        category: inferredCategory,
                        inferredName: inferredName,
                        firstVisit: cluster.firstVisit,
                        lastVisit: cluster.lastVisit
                    )
                }
                
                continuation.resume(returning: enhancedCluster)
            }
        }
    }
    
    private func inferPlaceCategory(from placemark: CLPlacemark) -> PlaceCategory {
        // Analyze placemark properties to infer venue type
        let name = placemark.name?.lowercased() ?? ""
        let thoroughfare = placemark.thoroughfare?.lowercased() ?? ""
        let subThoroughfare = placemark.subThoroughfare?.lowercased() ?? ""
        
        // Check for specific venue types based on naming patterns
        let combinedInfo = "\(name) \(thoroughfare) \(subThoroughfare)"
        
        if combinedInfo.contains("park") || combinedInfo.contains("trail") || combinedInfo.contains("beach") {
            return .park
        } else if combinedInfo.contains("mall") || combinedInfo.contains("shopping") {
            return .shopping
        } else if combinedInfo.contains("restaurant") || combinedInfo.contains("food") {
            return .restaurant
        } else if combinedInfo.contains("coffee") || combinedInfo.contains("cafe") {
            return .cafe
        } else if combinedInfo.contains("gym") || combinedInfo.contains("fitness") {
            return .gym
        } else if combinedInfo.contains("school") || combinedInfo.contains("university") {
            return .school
        } else if combinedInfo.contains("hospital") || combinedInfo.contains("medical") {
            return .hospital
        } else if name.isEmpty && placemark.subThoroughfare != nil {
            // Likely a residence if it has a street number but no specific name
            return .home
        }
        
        return .other
    }
    
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
        
        let categories = Dictionary(grouping: clusters, by: { $0.category })
        let topCategories = categories
            .sorted { $0.value.count > $1.value.count }
            .prefix(3)
            .map { "\($0.value.count) \($0.key.displayName.lowercased())" }
        
        if topCategories.count == 1 {
            return topCategories.first
        } else if topCategories.count == 2 {
            return topCategories.joined(separator: " and ")
        } else {
            return topCategories.dropLast().joined(separator: ", ") + ", and " + topCategories.last!
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
        case category, inferredName, firstVisit, lastVisit
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
        try container.encode(firstVisit, forKey: .firstVisit)
        try container.encode(lastVisit, forKey: .lastVisit)
    }
}
